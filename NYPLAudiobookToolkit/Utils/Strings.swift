//
//  Strings.swift
//  NYPLAudiobookToolkit
//
//  Created by Maurice Carrier on 12/8/22.
//  Copyright © 2022 Dean Silfen. All rights reserved.
//

import Foundation

struct Strings {
    struct AudiobookPlayerViewController {
        static let sleepTimer = NSLocalizedString("Sleep Timer", value: "Sleep Timer", comment:"Sleep Timer")
        static let tableOfContents = NSLocalizedString("Table of Contents",
                                                       value: "Table of Contents",
                                                       comment: "Title to describe the list of chapters or tracks.")
        static let chapterSelectionAccessibility = NSLocalizedString("Select a chapter or track from a list.",
                                                                  value: "Select a chapter or track from a list.",
                                                                  comment: "Explain what a table of contents is.")
        static let playbackSpeed = NSLocalizedString("Playback Speed", value: "Playback Speed", comment: "Title to set how fast the audio plays")
        static let currently = NSLocalizedString("currently", comment: "")
        static let cancel = NSLocalizedString("Cancel", value: "Cancel", comment: "Cancel")
        static let endOfChapter = NSLocalizedString("End of Chapter", value: "End of Chapter", comment: "End of Chapter")
        static let oneHour = NSLocalizedString("60 Minutes", value: "60 Minutes", comment: "60 Minutes")
        static let thirtyMinutes = NSLocalizedString("30 Minutes", value: "30 Minutes", comment: "30 Minutes")
        static let fifteenMinutes = NSLocalizedString("15 Minutes", value: "15 Minutes", comment: "15 Minutes")
        static let off = NSLocalizedString("Off", value: "Off", comment: "Off")
        static let playbackDestination = NSLocalizedString("Playback Destination", value: "Playback Destination", comment: "Describe where the sound can be sent. Example: Bluetooth Speakers.")
        static let addBookmark = NSLocalizedString("Add Bookmark", value: "Add Bookmark", comment: "Button enbaling user to add a bookmark.")
        static let addBookmarkAccessiblityHint = NSLocalizedString("Save the current location bookmark for later listening.",
                                                                  value: "Save the current location bookmark for later listening.",
                                                                  comment: "Explain how to set a bookmark.")
        static let bookmarkAdded = NSLocalizedString("Bookmark added",
                                                     value: "Bookmark added",
                                                     comment: "Notifies user that a bookmark has been set")
        static let destinationAvailabilityAccessiblityHint = NSLocalizedString("If another device is available, send the audio over Bluetooth or Airplay. Otherwise do nothing.", value: "If another device is available, send the audio over Bluetooth or Airplay. Otherwise do nothing.", comment: "Longer description to describe action of the button.")
        static let timeToPause = NSLocalizedString("%@ until playback pauses", value: "%@ until playback pauses", comment: "localized time until playback pauses, for voice over")
        static let trackAt = NSLocalizedString("Track %@", value: "Track %@", comment: "Default track title")
        static let fileNumber = NSLocalizedString("%@ (file %@ of %d)", value: "%@ (file %@ of %d)", comment: "Current chapter and the amount of chapters left in the book")
        static let problemHasOccurred = NSLocalizedString("A Problem Has Occurred",
                                                          value: "A Problem Has Occurred",
                                                          comment: "A Problem Has Occurred")
        static let tryAgain = NSLocalizedString("Please try again later.", comment: "Error message to please try again.")
        static let ok = NSLocalizedString("OK", value: "OK", comment: "Okay")
    }
    
    struct AudiobookTableOfContentsTableViewController {
        static let currentlyPlaying = NSLocalizedString("Currently Playing: %@",
                                                        value: "Currently Playing: %@",
                                                        comment: "Announce which track is highlighted in the table of contents.")
        static let chapters = NSLocalizedString("Chapters", comment: "")
        static let bookmarks = NSLocalizedString("Bookmarks", comment: "")

    }
    
    struct Generic {
        static let downloading = NSLocalizedString("Downloading:", value: "Downloading:", comment: "")
        static let downloadingFormatted = NSLocalizedString("Downloading: %@%%", value: "Downloading: %@%%", comment: "The percentage of the chapter that has been downloaded, formatting for string should be localized at this point.")
        static let loading = NSLocalizedString("Downloading: %@%%", value: "Downloading: %@%%", comment: "The percentage of the chapter that has been downloaded, formatting for string should be localized at this point.")
        static let pause = NSLocalizedString("Pause", value: "Pause", comment: "Pause")
        static let play = NSLocalizedString("Play", value: "Play", comment: "Play")
        static let sec = NSLocalizedString("sec", value: "sec", comment: "Abbreviations for seconds")
        static let back = NSLocalizedString("Back", comment: "Back button")
    }
    
    struct Error {
        static let bookmarkAlreadyExistsError = NSLocalizedString("A bookmark has already been saved at this location.", comment: "Alert notifying user that location has already been saved.")
        static let failedToSaveBookmarkError = NSLocalizedString("Internal Error, bookmark failed to save.", comment: "Alert notifying user that bookmark save failed.")
    }
    
    struct PlaybackControlView {
        static let rewind = NSLocalizedString("Rewind %d seconds", value: "Rewind %d seconds", comment: "Rewind a configurable number of seconds")
        static let forward = NSLocalizedString("Fast Forward %d seconds", value: "Fast Forward %d seconds", comment: "Fast forward a configurable number of seconds")
    }
    
    struct ScrubberView {
        static let timeRemaining = NSLocalizedString("%@ remaining", value: "%@ remaining", comment: "The amount of hours and minutes left")
        static let timeRemainingInBook = NSLocalizedString("%@ remaining in the book.",
                                                          value: "%@ remaining in the book.",
                                                          comment: "How much time is left in the entire book, not just the chapter.")
        static let playedVsRemaining = NSLocalizedString("%@ played. %@ remaining.",
                                                         value: "%@ played. %@ remaining.",
                                                         comment: "Time into the current chapter, then time remaining in the current chapter.")
        
    }
}
