// The settings of the open piano, changed by the app through the engine.
//
// The web's app.js changes `engine.settings` in place and then asks the
// engine to follow (setSetting, applyKeyCount, fitRefToPiano). The engine
// owns its piano, so in the Mac app those steps are engine commands: the
// app sends them to the engine's queue, and the change reaches the saved
// piano with the engine's next changes, never past them.

extension Engine {
    /// Changes the settings as app.js's setSetting does: `edit` changes
    /// them and the targets are computed again. A new key count also builds
    /// the tuning order again and keeps the key on the keyboard
    /// (applyKeyCount). The strings per key and the unisons go through
    /// ``setStrings(two:one:)`` and ``setUnisons(_:)``, which build the order
    /// too; clamping is the caller's (``clampRef(_:)``, ``clampSize(_:_:)``),
    /// as in the web.
    public func setSettings(_ edit: (inout Settings) -> Void) {
        let keys = settings.keyCount
        edit(&piano.settings)
        recompute()
        if settings.keyCount != keys {
            rebuildOrder()
            if key > top { selectKey(top, manual: false) }
        }
    }

    /// Sets the reference so the middle of the piano is on target (app.js:
    /// fitRefToPiano, from ``fitRefHz``, clamped). Returns the reference
    /// set, or nil when nothing tells where the piano is: no before values
    /// in the middle and no key sounding.
    @discardableResult
    public func fitRef() -> Double? {
        let hz = fitRefHz
        guard hz.isFinite else { return nil }
        setSettings { $0.refA4 = Self.clampRef(hz) }
        return settings.refA4
    }
}
