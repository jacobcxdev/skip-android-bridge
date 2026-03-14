// Copyright 2024–2025 Skip
// SPDX-License-Identifier: LGPL-3.0-only WITH LGPL-3.0-linking-exception
#if SKIP
import Foundation
import OSLog

fileprivate let logger: Logger = Logger(subsystem: "skip.android.bridge", category: "AndroidBridge")
#else
import Foundation
@_exported import SkipBridge
@_exported import SwiftJNI
#if canImport(FoundationNetworking)
@_exported import FoundationNetworking
#endif
#if canImport(AndroidLogging)
@_exported import AndroidLogging
#elseif canImport(OSLog)
@_exported import OSLog
#endif
#if canImport(AndroidLooper)
@_exported import AndroidLooper
#endif
#if canImport(AndroidNative)
import AndroidNative
#endif
fileprivate let logger: Logger = Logger(subsystem: "skip.android.bridge", category: "AndroidBridge")
#endif

#if os(Android) || ROBOLECTRIC
public let isAndroid = true
#else
public let isAndroid = false
#endif

#if SKIP


/// The entry point from a Kotlin Main.kt into the bridged `SkipAndroidBridge`.
///
/// This class handles the initial Kotlin-side setup of the Swift bridging, which currently
/// just involves loading the specific library and calling the Swift `AndroidBridgeBootstrap.initAndroidBridge()`,
/// which will, in turn, perform all the Foundation-level setup.
public class AndroidBridge {
    /// This is called at app initialization time by reflection from the `Main.kt`
    ///
    /// It will look like: `skip.android.bridge.AndroidBridge.initBridge("AppDroidModel")`
    public static func initBridge(_ libraryNames: String) throws {
        for libraryName in libraryNames.split(separator: ",") {
            do {
                logger.debug("loading library: \(libraryName)")
                try System.loadLibrary(libraryName)
            } catch {
                android.util.Log.e("SkipBridge", "error loading bridge library: \(libraryName)", error as? ErrorException)
            }
        }

        let context = ProcessInfo.processInfo.androidContext
        let locale = java.util.Locale.getDefault().toLanguageTag()
        try AndroidBridgeBootstrap.initAndroidBridge(filesDir: context.getFilesDir().getAbsolutePath(), cacheDir: context.getCacheDir().getAbsolutePath(), locale: locale)
    }
}
#endif

/// Called from Kotlin's `AndroidBridge.initBridge` to perform setup that is needed to
/// get `Foundation` idioms working with Android conventions.
// SKIP @bridge
public class AndroidBridgeBootstrap {
    private static var androidBridgeInit = false

    /// The device's locale identifier (BCP 47 language tag), as reported by the Android system.
    /// `nil` on non-Android platforms or before bridge initialization.
    public fileprivate(set) static var deviceLocaleIdentifier: String?

    /// Perform all the setup that is needed to get `Foundation` idioms working with Android conventions.
    ///
    /// This includes:
    /// - Using the Android certificate store for HTTPS validation
    /// - Using the Android context file locations for `FileManager.url`
    // SKIP @bridge
    public static func initAndroidBridge(filesDir: String, cacheDir: String, locale: String) throws {
        if Self.androidBridgeInit == true { return }
        defer { Self.androidBridgeInit = true }

        let start = Date.now
        logger.debug("initAndroidBridge: start")
        #if os(Android) || ROBOLECTRIC
        logger.debug("initAndroidBridge: bootstrapFileManagerProperties")
        try bootstrapFileManagerProperties(filesDir: filesDir, cacheDir: cacheDir)
        #endif
        #if os(Android)
        logger.debug("initAndroidBridge: AssetURLProtocol.register")
        try AssetURLProtocol.register()
        logger.debug("initAndroidBridge: bootstrapTimezone")
        try bootstrapTimezone()
        logger.debug("initAndroidBridge: bootstrapLocale")
        bootstrapLocale(languageTag: locale)
        logger.debug("initAndroidBridge: setupCACerts")
        try AndroidBootstrap.setupCACerts()
        logger.debug("initAndroidBridge: AndroidLooper.setupMainLooper")
        let _ = AndroidLooper.setupMainLooper()
        logger.debug("initAndroidBridge: done")
        #endif
        logger.debug("AndroidBridgeBootstrap.initAndroidBridge done in \(Date.now.timeIntervalSince(start)) applicationSupportDirectory=\(URL.applicationSupportDirectory.path)")
    }
}

private func bootstrapTimezone() throws {
    // Until https://github.com/swiftlang/swift-foundation/pull/1053 gets merged
    tzset()
    var t = time(nil)
    var lt : tm = tm()
    localtime_r(&t, &lt)
    if let zoneptr = lt.tm_zone, let name = String(validatingUTF8: zoneptr) {
        //logger.debug("detected timezone: \(name)")
        setenv("TZ", name, 0)
    }

}

private func bootstrapLocale(languageTag: String) {
    // Swift Foundation on non-Darwin hardcodes Locale.current to en_001 (Locale_Cache.swift),
    // ignoring the Android device locale. Store it and set LANG for POSIX/C APIs.
    AndroidBridgeBootstrap.deviceLocaleIdentifier = languageTag
    let posix = languageTag.replacingOccurrences(of: "-", with: "_")
    setenv("LANG", posix + ".UTF-8", 1)
}

private func bootstrapFileManagerProperties(filesDir: String, cacheDir: String) throws {
    // https://github.com/swiftlang/swift-foundation/blob/main/Sources/FoundationEssentials/FileManager/SearchPaths/FileManager%2BXDGSearchPaths.swift#L46
    setenv("XDG_CACHE_HOME", cacheDir, 0)
    // https://github.com/swiftlang/swift-foundation/blob/main/Sources/FoundationEssentials/FileManager/SearchPaths/FileManager%2BXDGSearchPaths.swift#L37
    setenv("XDG_DATA_HOME", filesDir, 0)

    // Also set the environment needed for UserDefaults to be able to persist to the filesystem
    // https://github.com/swiftlang/swift-corelibs-foundation/blob/main/Sources/CoreFoundation/CFPlatform.c#L331C66-L331C83
    setenv("CFFIXED_USER_HOME", filesDir, 0)

    // ensure that we can get the `.applicationSupportDirectory`, which should use the `XDG_DATA_HOME` environment
    //let applicationSupportDirectory = URL.applicationSupportDirectory // unavailable on Android
    let applicationSupportDirectory = try! FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    logger.debug("bootstrapFileManagerProperties: applicationSupportDirectory=\(applicationSupportDirectory.path)")
}

// URL.applicationSupportDirectory exists in Darwin's Foundation but not in Android's Foundation
#if os(Android)
// SKIP @nobridge
extension URL {
    public static var applicationSupportDirectory: URL {
        try! FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
    }

    public static var cachesDirectory: URL {
        try! FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
    }
}

#endif

// MARK: - Device Locale

extension Locale {
    /// The device's actual locale.
    ///
    /// On Android, Swift Foundation hardcodes `Locale.current` to `en_001` (English - World),
    /// ignoring the device locale. This property returns the locale reported by
    /// `java.util.Locale.getDefault()`, bridged during `AndroidBridgeBootstrap.initAndroidBridge`.
    /// On other platforms, returns `Locale.current`.
    public static var device: Locale {
        if let id = AndroidBridgeBootstrap.deviceLocaleIdentifier {
            return Locale(identifier: id)
        }
        return .current
    }
}

extension Date {
    /// Formats using the device's actual locale.
    ///
    /// Equivalent to `formatted()` on Apple platforms. On Android, works around Swift Foundation
    /// hardcoding `Locale.current` to `en_001` by using `Locale.device`.
    public func deviceFormatted() -> String {
        self.formatted(Date.FormatStyle(date: .numeric, time: .shortened).locale(.device))
    }

    /// Formats using the device's actual locale with the specified date and time styles.
    public func deviceFormatted(date: Date.FormatStyle.DateStyle, time: Date.FormatStyle.TimeStyle) -> String {
        self.formatted(Date.FormatStyle(date: date, time: time).locale(.device))
    }
}
