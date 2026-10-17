import ClipKit
import Foundation
import Observation

/// The browser's view of the photo library: photos grouped by day.
@MainActor
@Observable
final class LibraryModel {
    struct Day: Identifiable, Hashable {
        let id: String          // yyyy-MM-dd
        let date: Date
        var photos: [PhotoLibrary.Photo]
        var year: String { String(id.prefix(4)) }
    }

    private(set) var days: [Day] = []
    private(set) var isLoading = false
    var selectedDayID: String?

    var selectedDay: Day? { days.first { $0.id == selectedDayID } }
    var photoCount: Int { days.reduce(0) { $0 + $1.photos.count } }

    private(set) var library: PhotoLibrary

    init(root: URL) {
        library = PhotoLibrary(root: root)
    }

    func setRoot(_ root: URL) {
        library = PhotoLibrary(root: root)
        selectedDayID = nil
        reload()
    }

    /// Re-reads the Photos folder (file names only, so this is quick even for many photos).
    func reload() {
        isLoading = true
        let library = library
        Task.detached(priority: .userInitiated) {
            let photos = library.allPhotos()
            let grouped = Dictionary(grouping: photos, by: \.day)
            let days = grouped.map { Day(id: $0.key, date: $0.value[0].date, photos: $0.value) }
                .sorted { $0.id > $1.id }
            await MainActor.run { self.apply(days) }
        }
    }

    private func apply(_ newDays: [Day]) {
        days = newDays
        isLoading = false
        if selectedDayID == nil || !days.contains(where: { $0.id == selectedDayID }) {
            selectedDayID = days.first?.id
        }
    }

    /// Moves the photos (and their metadata) to the Trash. Returns an error message on failure.
    func delete(_ photos: [PhotoLibrary.Photo]) -> String? {
        guard !photos.isEmpty else { return nil }
        defer { reload() }
        do {
            try library.delete(photos)
            // Update immediately so the grid doesn't flash the deleted photos until reload lands.
            let gone = Set(photos.map(\.id))
            days = days.compactMap { day in
                var day = day
                day.photos.removeAll { gone.contains($0.id) }
                return day.photos.isEmpty ? nil : day
            }
            return nil
        } catch {
            return String(localized: "Couldn't delete: \(error.localizedDescription)")
        }
    }
}
