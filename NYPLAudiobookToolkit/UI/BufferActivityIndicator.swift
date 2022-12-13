class BufferActivityIndicatorView: UIActivityIndicatorView {

    var debounceTimer: Timer? = nil {
        willSet {
            debounceTimer?.invalidate()
        }
    }

    private let debounceTimeInterval = 1.0

    override func startAnimating() {
        DispatchQueue.main.async {
            super.startAnimating()
        }
        
        // Announce a "buffer" to VoiceOver with sufficient debounce...
        if debounceTimer == nil {
            debounceTimer = Timer.scheduledTimer(timeInterval: debounceTimeInterval,
                                                 target: self,
                                                 selector: #selector(debounceFunction),
                                                 userInfo: nil,
                                                 repeats: false)
        }
    }

    override func stopAnimating() {
        DispatchQueue.main.async {
            super.stopAnimating()
        }
        debounceTimer?.invalidate()
        debounceTimer = nil
    }

    @objc func debounceFunction() {
        let announcementString = Strings.Generic.loading
        UIAccessibility.post(notification: .announcement, argument: announcementString)
    }
}
