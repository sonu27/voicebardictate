import Foundation

struct LiveTranscriptSnapshot {
    let previewText: String
    let finalText: String
}

final class LiveTranscriptAccumulator {
    private var orderedItemIDs: [String] = []
    private var liveTextByItemID: [String: String] = [:]
    private var finalTextByItemID: [String: String] = [:]

    func reset() {
        orderedItemIDs.removeAll(keepingCapacity: true)
        liveTextByItemID.removeAll(keepingCapacity: true)
        finalTextByItemID.removeAll(keepingCapacity: true)
    }

    @discardableResult
    func handleCommitted(itemID: String, previousItemID: String?) -> LiveTranscriptSnapshot {
        registerItem(itemID, previousItemID: previousItemID)
        return snapshot()
    }

    @discardableResult
    func handleDelta(itemID: String, delta: String) -> LiveTranscriptSnapshot {
        registerItem(itemID, previousItemID: nil)
        liveTextByItemID[itemID, default: ""].append(delta)
        return snapshot()
    }

    @discardableResult
    func handleCompleted(itemID: String, text: String) -> LiveTranscriptSnapshot {
        registerItem(itemID, previousItemID: nil)
        finalTextByItemID[itemID] = text
        return snapshot()
    }

    func snapshot() -> LiveTranscriptSnapshot {
        let orderedSegments = orderedItemIDs.map { itemID -> String in
            let final = finalTextByItemID[itemID]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !final.isEmpty {
                return final
            }
            return liveTextByItemID[itemID]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }.filter { !$0.isEmpty }

        let orderedFinalSegments = orderedItemIDs.map { itemID -> String in
            finalTextByItemID[itemID]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }.filter { !$0.isEmpty }

        return LiveTranscriptSnapshot(
            previewText: orderedSegments.joined(separator: " "),
            finalText: orderedFinalSegments.joined(separator: " ")
        )
    }

    private func registerItem(_ itemID: String, previousItemID: String?) {
        if orderedItemIDs.contains(itemID) {
            return
        }

        guard let previousItemID, let index = orderedItemIDs.firstIndex(of: previousItemID) else {
            orderedItemIDs.append(itemID)
            return
        }

        orderedItemIDs.insert(itemID, at: index + 1)
    }
}
