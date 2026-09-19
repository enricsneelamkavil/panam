//
//  VoiceEntrySheet.swift
//  Panam
//

import SwiftUI
import SwiftData
import Speech
import AVFoundation

/// Captures speech, live-transcribes it, and hands the transcript to the
/// on-device model for parsing into transaction fields.
struct VoiceEntrySheet: View {
    @Environment(\.dismiss) private var dismiss

    let onParsed: (ParsedTransaction) -> Void

    @Query(sort: \Category.name) private var categories: [Category]
    @Query(sort: \Account.name) private var accounts: [Account]

    @State private var transcript = ""
    @State private var isRecording = false
    @State private var isParsing = false
    @State private var errorMessage: String?
    @State private var permissionDenied = false

    @State private var audioEngine = AVAudioEngine()
    @State private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @State private var recognitionTask: SFSpeechRecognitionTask?

    private var canUseTranscript: Bool {
        !isRecording && !isParsing
            && !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                TextEditor(text: $transcript)
                    .font(.title3)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(alignment: .topLeading) {
                        if transcript.isEmpty {
                            Text("Say something like \u{201C}320 rupees for lunch from HDFC\u{201D}")
                                .font(.title3)
                                .foregroundStyle(.tertiary)
                                .padding(16)
                                .allowsHitTesting(false)
                        }
                    }

                if permissionDenied {
                    Text("Microphone or speech recognition permission was denied. Enable both in Settings to use voice entry.")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let errorMessage {
                    VStack(spacing: 8) {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Try typing instead") {
                            dismiss()
                        }
                        .font(.caption)
                    }
                }

                Button {
                    toggleRecording()
                } label: {
                    Image(systemName: isRecording ? "mic.fill" : "mic")
                        .font(.system(size: 32))
                        .frame(width: 72, height: 72)
                        .background(isRecording ? Color.red.opacity(0.2) : Color.accentColor.opacity(0.15),
                                    in: Circle())
                        .foregroundStyle(isRecording ? .red : Color.accentColor)
                }
                .disabled(permissionDenied || isParsing)

                Text(isRecording ? "Listening\u{2026} tap to stop" : "Tap to start recording")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    useTranscript()
                } label: {
                    if isParsing {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Use This")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canUseTranscript)
            }
            .padding()
            .navigationTitle("Voice Entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        stopRecording(discard: true)
                        dismiss()
                    }
                }
            }
            .onAppear(perform: requestPermissions)
            .onDisappear { stopRecording(discard: true) }
        }
    }

    private func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor in
                if status != .authorized {
                    permissionDenied = true
                }
            }
        }
        AVAudioApplication.requestRecordPermission { granted in
            Task { @MainActor in
                if !granted {
                    permissionDenied = true
                }
            }
        }
    }

    private func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            errorMessage = nil
            do {
                try startRecording()
            } catch {
                errorMessage = "Couldn't start recording: \(error.localizedDescription)"
            }
        }
    }

    private func startRecording() throws {
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            errorMessage = "Speech recognition isn't available right now."
            return
        }

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        try inputNode.installAudioTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            if let pcmBuffer = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(buffer.frameCapacity)) {
                pcmBuffer.frameLength = AVAudioFrameCount(buffer.frameLength)
                buffer.withUnsafeAudioBufferList { srcList in
                    let dstList = pcmBuffer.mutableAudioBufferList
                    let srcPointer = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: srcList))
                    let dstPointer = UnsafeMutableAudioBufferListPointer(dstList)
                    for i in 0..<srcPointer.count {
                        if let srcData = srcPointer[i].mData, let dstData = dstPointer[i].mData {
                            dstData.copyMemory(from: srcData, byteCount: Int(srcPointer[i].mDataByteSize))
                        }
                    }
                }
                request.append(pcmBuffer)
            }
        }

        audioEngine.prepare()
        try audioEngine.start()

        recognitionTask = recognizer.recognitionTask(with: request) { result, error in
            Task { @MainActor in
                if let result {
                    transcript = result.bestTranscription.formattedString
                }
                if error != nil {
                    stopRecording()
                }
            }
        }
        isRecording = true
    }

    /// `discard: false` (the normal "tap to stop" path) lets the recognizer
    /// finish processing buffered audio so the final, more accurate
    /// transcription result still lands. `discard: true` (Cancel button,
    /// onDisappear) abandons the task immediately.
    private func stopRecording(discard: Bool = false) {
        guard isRecording || recognitionTask != nil else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        if discard {
            recognitionTask?.cancel()
        } else {
            recognitionTask?.finish()
        }
        recognitionRequest = nil
        recognitionTask = nil
        isRecording = false
    }

    private func useTranscript() {
        isParsing = true
        errorMessage = nil
        Task {
            do {
                let parsed = try await VoiceTransactionParser.parse(
                    transcript: transcript,
                    categories: categories,
                    accounts: accounts
                )
                isParsing = false
                onParsed(parsed)
                dismiss()
            } catch {
                isParsing = false
                errorMessage = error.localizedDescription
            }
        }
    }
}
