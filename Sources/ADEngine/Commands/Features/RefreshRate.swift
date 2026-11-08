extension CommandValues {
    /// A positive whole rate, as `120` or as `get` prints it, `120Hz`.
    static func hz(_ text: String) -> Int? {
        let digits = text.lowercased().hasSuffix("hz") ? String(text.dropLast(2)) : text
        guard let rate = wholeNumber(digits), rate > 0 else { return nil }
        return rate
    }
}

extension CommandDispatcher {
    /// Rounded, so 119.88 Hz reads as `120Hz`, the same as modes are matched.
    func refreshRateValue(of device: SelectedDevice) -> String? {
        device.mode.map { "\(Int($0.refreshHz.rounded()))Hz" }
    }
}
