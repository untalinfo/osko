//
//  NotchView.swift
//  OSKO
//

import Foundation
import SwiftUI

struct NotchView: View {
    @ObservedObject var viewModel: OSKOViewModel
    @State private var floatStartTime = Date().timeIntervalSinceReferenceDate
    @State private var floatOffset: CGSize = .zero
    @State private var floatTiltDegrees: Double = 0.0

    private var canSend: Bool {
        viewModel.isModelLoaded
            && !viewModel.isThinking
            && !viewModel.userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var activeLanguageBadge: String {
        viewModel.activeSpeechLocale.lowercased().hasPrefix("es") ? "ES" : "EN"
    }

    var body: some View {
        VStack(spacing: 8) {
            // OSKO's minimalist physical presence — slightly asymmetric organic-tech silhouette
            ZStack {
                OSKOBodyShape()
                    .fill(Color.oskoPetrolBlue)
                    .overlay(
                        OSKOBodyShape()
                            .stroke(Color.oskoTurquoise.opacity(0.45), lineWidth: 0.75)
                    )

                OSKOEyesView(viewModel: viewModel)

                if !viewModel.isModelLoaded && viewModel.modelError == nil {
                    Circle()
                        .fill(Color.oskoSilver.opacity(0.75))
                        .frame(width: 3.5, height: 3.5)
                        .offset(x: 20, y: 0)
                        .accessibilityLabel("Cargando modelo")
                }
            }
            .frame(
                width: OSKOPanelLayout.collapsedBodySize.width,
                height: OSKOPanelLayout.collapsedBodySize.height
            )
            .clipShape(OSKOBodyShape())
            .contentShape(OSKOBodyShape())
            .rotationEffect(.degrees(floatTiltDegrees))
            .offset(floatOffset)
            .onTapGesture {
                withAnimation(.spring(response: 0.30, dampingFraction: 0.85)) {
                    viewModel.togglePanelExpanded()
                }
            }

            if viewModel.isPanelExpanded {
                VStack(spacing: 0) {
                    statusHeader

                    if !viewModel.chatHistory.isEmpty {
                        ScrollViewReader { proxy in
                            ScrollView {
                                VStack(alignment: .leading, spacing: 12) {
                                    ForEach(viewModel.chatHistory) { message in
                                        ChatBubble(
                                            message: message,
                                            onSpeak: (!message.isUser && !message.isError)
                                                ? { viewModel.speakMessage(message.text) }
                                                : nil
                                        )
                                        .id(message.id)
                                    }
                                }
                                .padding()
                            }
                            .frame(maxHeight: 340)
                            .onChange(of: viewModel.chatHistory.count) { _, _ in
                                guard let lastID = viewModel.chatHistory.last?.id else { return }
                                withAnimation(.easeOut(duration: 0.15)) {
                                    proxy.scrollTo(lastID, anchor: .bottom)
                                }
                            }
                            .onChange(of: viewModel.chatHistory.last?.text) { _, _ in
                                guard let lastID = viewModel.chatHistory.last?.id else { return }
                                proxy.scrollTo(lastID, anchor: .bottom)
                            }
                        }
                    }

                    HStack(spacing: 6) {
                        Button(action: { viewModel.toggleVoiceListening() }) {
                            Image(systemName: viewModel.isListening ? "mic.fill" : "mic")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 14, height: 14)
                                .padding(7)
                                .background(
                                    Circle()
                                        .fill(viewModel.isListening ? Color.oskoTurquoise : Color.white.opacity(0.08))
                                )
                                .foregroundColor(viewModel.isListening ? Color.oskoAmber : Color.oskoSilver)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(viewModel.isListening ? "Detener escucha de voz" : "Activar escucha de voz")

                        Button(action: { viewModel.toggleSpeechLocaleBetweenSpanishAndEnglish() }) {
                            Text(activeLanguageBadge)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.white.opacity(0.08))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.oskoSilver.opacity(0.22), lineWidth: 0.75)
                                )
                                .foregroundColor(Color.oskoSilver)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Cambiar idioma de reconocimiento de voz (\(activeLanguageBadge))")

                        TextField("Piensa conmigo...", text: $viewModel.userInput)
                            .textFieldStyle(.plain)
                            .padding(10)
                            .background(Color.white.opacity(0.08))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.oskoSilver.opacity(0.18), lineWidth: 1)
                            )
                            .cornerRadius(8)
                            .foregroundColor(.white)
                            .onSubmit {
                                submitMessage()
                            }

                        Button(action: { viewModel.handleSpeakerButtonTapped() }) {
                            Image(systemName: viewModel.isVoiceOutputEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 15, height: 15)
                                .padding(6)
                                .foregroundColor(viewModel.isVoiceOutputEnabled ? Color.oskoAmber : Color.oskoSilver.opacity(0.45))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(viewModel.isVoiceOutputEnabled ? "Escuchar o silenciar voz de OSKO" : "Activar voz de OSKO")

                        Button(action: submitMessage) {
                            Image(systemName: "arrow.up.circle.fill")
                                .resizable()
                                .frame(width: 28, height: 28)
                                .foregroundColor(canSend ? Color.oskoAmber : Color.oskoSilver.opacity(0.35))
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSend)
                        .accessibilityLabel("Enviar mensaje")
                    }
                    .padding()
                }
                .frame(width: OSKOPanelLayout.expandedCardWidth)
                .background(Color.oskoPetrolBlue.opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(Color.oskoTurquoise.opacity(0.35), lineWidth: 1)
                )
                .cornerRadius(20)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            Spacer(minLength: 0)
        }
        .padding(.top, OSKOPanelLayout.topPadding)
        .frame(
            width: viewModel.isPanelExpanded
                ? OSKOPanelLayout.expandedPanelSize.width
                : OSKOPanelLayout.collapsedPanelSize.width,
            height: viewModel.isPanelExpanded
                ? OSKOPanelLayout.expandedPanelSize.height
                : OSKOPanelLayout.collapsedPanelSize.height,
            alignment: .top
        )
        .task {
            while !Task.isCancelled {
                let elapsed = Date().timeIntervalSinceReferenceDate - floatStartTime
                let pose = OSKOGazeMath.floatingPose(
                    at: elapsed,
                    emotion: viewModel.currentEmotion,
                    isThinking: viewModel.isThinking
                )
                floatOffset = pose.offset
                floatTiltDegrees = pose.tiltDegrees
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    @ViewBuilder
    private var statusHeader: some View {
        if let error = viewModel.modelError {
            HStack(spacing: 8) {
                Text("Error al cargar: \(error)")
                    .font(.caption2)
                    .foregroundColor(Color.oskoSilver)
                    .lineLimit(2)
                Spacer()
                Button("Reintentar") {
                    viewModel.retryModelLoad()
                }
                .font(.caption2.weight(.medium))
                .foregroundColor(Color.oskoAmber)
                .buttonStyle(.plain)
            }
            .padding(.horizontal)
            .padding(.top, 12)
        } else if !viewModel.isModelLoaded {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.oskoSilver.opacity(0.85))
                    .frame(width: 5, height: 5)
                Text("Despertando...")
                    .font(.caption2)
                    .foregroundColor(Color.oskoSilver)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top, 12)
        } else if viewModel.isThinking {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.oskoAmber.opacity(0.85))
                    .frame(width: 5, height: 5)
                Text("Pensando...")
                    .font(.caption2)
                    .foregroundColor(Color.oskoSilver)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top, 12)
        } else if viewModel.isListening {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.oskoTurquoise)
                    .frame(width: 5, height: 5)
                Text("Escuchando (\(viewModel.activeSpeechLocale))...")
                    .font(.caption2)
                    .foregroundColor(Color.oskoSilver)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top, 12)
        } else if let speechMessage = viewModel.speechStatusMessage {
            HStack(spacing: 6) {
                Text(speechMessage)
                    .font(.caption2)
                    .foregroundColor(Color.oskoSilver)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top, 12)
        }
    }

    private func submitMessage() {
        guard canSend else { return }
        withAnimation(.spring(response: 0.30, dampingFraction: 0.85)) {
            viewModel.setPanelExpanded(true)
        }
        viewModel.sendMessage()
    }
}

struct ChatBubble: View {
    let message: ChatMessage
    var onSpeak: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if message.isUser { Spacer() }

            Text(message.text)
                .padding(10)
                .background(message.isUser ? Color.oskoTurquoise : Color.white.opacity(0.12))
                .foregroundColor(message.isUser ? .white : Color.oskoSilver)
                .cornerRadius(12)

            if let onSpeak {
                Button(action: onSpeak) {
                    Image(systemName: "speaker.wave.2.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 11, height: 11)
                        .padding(5)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                        .foregroundColor(Color.oskoAmber)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Escuchar respuesta de OSKO")
            }

            if !message.isUser { Spacer() }
        }
    }
}
