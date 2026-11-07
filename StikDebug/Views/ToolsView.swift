//
//  ToolsView.swift
//  StikDebug
//
//  Created by Stephen on 2/23/26.
//

import SwiftUI

struct ToolsView: View {
    @ObservedObject private var workspace = LocationWorkspaceStore.shared
    @State private var path: [AppFeature] = []

    var body: some View {
        NavigationStack(path: $path) {
            List(AppFeature.toolList) { tool in
                NavigationLink(value: tool) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tool.toolTitle)
                            Text(tool.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: tool.systemImage)
                    }
                }
            }
            .navigationTitle("Tools".localized)
            .navigationDestination(for: AppFeature.self) { $0.destination }
        }
        .onChange(of: workspace.incoming?.id, initial: true) { _, id in
            if id != nil && path != [.location] { path = [.location] }
        }
    }
}

