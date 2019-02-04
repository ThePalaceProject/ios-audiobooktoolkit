let OpenAccessPlayerDomain = "org.nypl.labs.NYPLAudiobookToolkit.OpenAccessPlayer"

/// Error Code : Description
let OpenAccessPlayerErrorDescriptions = [
    0 : """
    An unknown error has occurred. Please leave the book, and try again.
    If the problem persists, go to Settings and sign out.
    """,
    1 : """
    This chapter has not finished downlading. Please wait and try again.
    """,
    2 : """
    A problem has occurred with the Player. Please wait a moment and try again.
    If the problem persists, please contact us.
    """,
    3 : """
    The internet connection was lost during the download.
     Wait until you are back online, leave the book and try again.
    """
]

/// Error Code : Alert Title
let OpenAccessPlayerErrorTitle = [
    1 : "Please Wait",
    3 : "Connection Lost"
]
