import SwiftUI

/// The chip at the left of the bar: the active model, local (filled dot) or
/// cloud (ring). Opens the picker.
struct ModelChip: View {
    @ObservedObject var models: ModelStore
    @ObservedObject var ui: XoolUI

    var body: some View {
        XoolButton(action: { ui.showModels.toggle() }) {
            HStack(spacing: 6) {
                Image(systemName: models.current?.isLocal == false ? "circle" : "circle.fill")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Theme.textMuted)
                Text(chipTitle)
                    .font(Theme.small)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
            }
            .padding(.horizontal, Theme.Space.s)
        }
        .accessibilityLabel("Model: \(chipTitle)")
        .popover(isPresented: $ui.showModels, arrowEdge: .top) {
            ModelPicker(models: models, ui: ui)
        }
    }

    private var chipTitle: String {
        guard let current = models.current else { return "No model" }
        return current.label + (current.isLocal ? " · local" : " · cloud")
    }
}

struct ModelPicker: View {
    @ObservedObject var models: ModelStore
    @ObservedObject var ui: XoolUI
    /// Picked: nil closes only; set for choosing a model for one agent.
    var onPick: ((ModelChoice) -> Void)?
    @XState private var query = ""
    @FocusState private var searching: Bool

    private func matches(_ entry: ModelStore.Entry) -> Bool {
        query.isEmpty || entry.title.localizedCaseInsensitiveContains(query) || entry.detail.localizedCaseInsensitiveContains(query)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textMuted).font(.system(size: 11))
                TextField("Search models", text: $query)
                    .textFieldStyle(.plain)
                    .font(Theme.body)
                    .focused($searching)
                    .accessibilityLabel("Search models")
            }
            .padding(Theme.Space.m)
            Divider().overlay(Theme.line)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    group("Local", models.local.filter(matches),
                          empty: models.refreshing ? "Looking for Ollama and LM Studio…"
                              : "No local model found. \(models.offline.joined(separator: " and ")) isn't running, or has no model yet.")
                    group("Cloud", models.cloud.filter(matches),
                          empty: "Cloud models appear once you add a key in Settings › Models.")
                }
                .padding(Theme.Space.s)
            }
            .frame(maxHeight: 320)
            Divider().overlay(Theme.line)
            XoolButton(action: {
                ui.showModels = false
                Browsers.frontBrowser.settingsPage = .models
                Browsers.frontBrowser.tuning = true
            }) {
                Label("Models and keys…", systemImage: "gearshape")
                    .font(Theme.small)
                    .foregroundStyle(Theme.textMuted)
                    .padding(.horizontal, Theme.Space.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(Theme.Space.xs)
        }
        .frame(width: 340)
        .background(Theme.raised)
        .onAppear { searching = true; Task { await models.refresh() } }
    }

    @ViewBuilder
    private func group(_ title: String, _ entries: [ModelStore.Entry], empty: String) -> some View {
        Text(title).font(Theme.caption).foregroundStyle(Theme.textMuted)
            .padding(.horizontal, Theme.Space.s)
        if entries.isEmpty {
            Text(empty).font(Theme.small).foregroundStyle(Theme.textMuted)
                .padding(.horizontal, Theme.Space.s).padding(.bottom, Theme.Space.xs)
                .fixedSize(horizontal: false, vertical: true)
        }
        ForEach(entries) { entry in
            XoolButton(action: {
                if let onPick { onPick(entry.choice) } else { models.current = entry.choice }
                ui.showModels = false
            }) {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .opacity(models.current == entry.choice ? 1 : 0)
                        .frame(width: 12)
                    Text(entry.title).font(Theme.body).foregroundStyle(Theme.text).lineLimit(1)
                    Spacer(minLength: 4)
                    if let fit = entry.fit {
                        Image(systemName: fit.symbol).font(.system(size: 10)).foregroundStyle(Theme.textMuted)
                            .help("\(entry.sizeText), \(fit.words)")
                        Text(entry.sizeText).font(Theme.caption).foregroundStyle(Theme.textMuted)
                    }
                    Text(entry.detail).font(Theme.caption).foregroundStyle(Theme.textMuted)
                }
                .padding(.horizontal, Theme.Space.s)
            }
            .accessibilityLabel("\(entry.title), \(entry.detail)" + (entry.fit.map { ", \(entry.sizeText), \($0.words)" } ?? ""))
        }
    }
}
