// Copyright 2024–2025 Skip
// SPDX-License-Identifier: LGPL-3.0-only WITH LGPL-3.0-linking-exception
#if SKIP_BRIDGE

import CJNI
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
#if canImport(Android)
import Android
#endif
import Dispatch
import os

public struct BridgeObservation {
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    public struct BridgeObservationRegistrar: Sendable, Equatable, Hashable {
        private let registrar = ObservationModule.ObservationRegistrarType()
        private let bridgeSupport = BridgeObservationSupport()

        public init() {
        }

        public func access<Subject, Member>(_ subject: Subject, keyPath: KeyPath<Subject, Member>) where Subject : Observable {
            if ObservationRecording.isRecording {
                ObservationRecording.recordAccess(
                    replay: { [registrar] in registrar.access(subject, keyPath: keyPath) },
                    trigger: { [bridgeSupport] in bridgeSupport.triggerSingleUpdate() }
                )
            }
            bridgeSupport.access(subject, keyPath: keyPath)
            registrar.access(subject, keyPath: keyPath)
        }

        public func willSet<Subject, Member>(_ subject: Subject, keyPath: KeyPath<Subject, Member>) where Subject : Observable {
            if !ObservationRecording.isEnabled {
                bridgeSupport.willSet(subject, keyPath: keyPath)
            }
            registrar.willSet(subject, keyPath: keyPath)
        }

        public func didSet<Subject, Member>(_ subject: Subject, keyPath: KeyPath<Subject, Member>) where Subject : Observable {
            registrar.didSet(subject, keyPath: keyPath)
        }

        public func withMutation<Subject, Member, T>(of subject: Subject, keyPath: KeyPath<Subject, Member>, _ mutation: () throws -> T) rethrows -> T where Subject : Observable {
            if !ObservationRecording.isEnabled {
                bridgeSupport.willSet(subject, keyPath: keyPath)
            }
            return try registrar.withMutation(of: subject, keyPath: keyPath, mutation)
        }

        public static func ==(_: Self, _: Self) -> Bool {
            return true
        }

        public func hash(into hasher: inout Hasher) {
        }

        public init(from decoder: any Decoder) throws {
        }

        public func encode(to encoder: any Encoder) throws {
        }
    }

    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    public typealias Observable = ObservationModule.ObservableType

    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    public func withObservationTracking<T>(_ apply: () -> T, onChange: @autoclosure () -> @Sendable () -> Void) -> T {
        return ObservationModule.withObservationTrackingFunc(apply, onChange: onChange())
    }
}

/// Stack-based recording of observation accesses during Fuse-mode body evaluation.
/// Enables the record & replay pattern: access() calls during body eval are recorded,
/// then replayed inside withObservationTracking to set up proper observation subscriptions.
///
/// Uses a stack to handle nested Evaluate() calls (parent view body contains child Fuse views).
/// Each startRecording() pushes a new frame; each stopAndObserve() pops and processes its own frame.
@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
public final class ObservationRecording {
    /// True once hooks are registered — gates bridgeSupport.willSet() suppression.
    /// When false (no hooks), bridgeSupport.willSet() fires normally (original behavior).
    /// When true, withObservationTracking handles recomposition instead.
    /// This is intentionally a one-way flag: set once at app startup when the native
    /// bridge loads. The bridge is either present or not — there is no use case for
    /// disabling it at runtime.
    public static var isEnabled = false

    /// Opt-in diagnostics: logs every record/replay cycle with timing.
    /// Enable with `ObservationRecording.diagnosticsEnabled = true`.
    public static var diagnosticsEnabled = false

    /// Callback for diagnostics consumers. Called on every stopAndObserve()
    /// with the number of replayed closures and elapsed time in seconds.
    public static var diagnosticsHandler: ((Int, TimeInterval) -> Void)?

    // MARK: - Thread-local stack

    /// Thread-local key for per-thread recording stack.
    /// Each thread gets its own independent stack, matching the per-call-chain
    /// semantics of Compose recomposition which can invoke Evaluate() on
    /// different threads concurrently.
    private static let tlsKey: pthread_key_t = {
        var key: pthread_key_t = 0
        pthread_key_create(&key) { ptr in
            // Destructor: release the Unmanaged box when thread exits
            // Note: ptr optionality varies by platform (Darwin/Android SDK = Optional,
            // Skip/Bionic = non-Optional). Assign to Optional to satisfy both.
            let rawPtr: UnsafeMutableRawPointer? = ptr
            guard let rawPtr else { return }
            Unmanaged<FrameStack>.fromOpaque(rawPtr).release()
        }
        return key
    }()

    private final class FrameStack {
        var frames: [Frame] = []
    }

    private static var threadStack: FrameStack {
        if let ptr = pthread_getspecific(tlsKey) {
            return Unmanaged<FrameStack>.fromOpaque(ptr).takeUnretainedValue()
        }
        let stack = FrameStack()
        pthread_setspecific(tlsKey, Unmanaged.passRetained(stack).toOpaque())
        return stack
    }

    /// Whether we're currently recording access() calls during body eval
    public static var isRecording: Bool { !threadStack.frames.isEmpty }

    /// A single recording frame for one view's body evaluation.
    private struct Frame {
        var replayClosures: [() -> Void] = []
        var triggerClosure: (() -> Void)?
    }

    public static func startRecording() {
        threadStack.frames.append(Frame())
    }

    public static func stopAndObserve() {
        guard let frame = threadStack.frames.popLast() else { return }
        guard !frame.replayClosures.isEmpty else { return }
        guard let trigger = frame.triggerClosure else {
            assertionFailure("ObservationRecording: replay closures recorded but no trigger")
            return
        }

        let closures = frame.replayClosures
        let startTime = diagnosticsEnabled ? ProcessInfo.processInfo.systemUptime : 0
        ObservationModule.withObservationTrackingFunc({
            for closure in closures {
                closure()
            }
        }, onChange: {
            DispatchQueue.main.async {
                trigger()
            }
        })
        if diagnosticsEnabled {
            let elapsed = ProcessInfo.processInfo.systemUptime - startTime
            diagnosticsHandler?(closures.count, elapsed)
        }
    }

    static func recordAccess(
        replay: @escaping () -> Void,
        trigger: @escaping () -> Void
    ) {
        let stack = threadStack
        guard !stack.frames.isEmpty else { return }
        stack.frames[stack.frames.count - 1].replayClosures.append(replay)
        // Any single MutableStateBacking.update(0) call triggers Compose recomposition
        // of the enclosing composable scope, regardless of which observable changed.
        // We only need one trigger closure since all observables share the same
        // recomposition boundary in a given view body.
        if stack.frames[stack.frames.count - 1].triggerClosure == nil {
            stack.frames[stack.frames.count - 1].triggerClosure = trigger
        }
    }
}

private final class BridgeObservationSupport: @unchecked Sendable {
    init() {
    }

    public func access<Subject, Member>(_ subject: Subject, keyPath: KeyPath<Subject, Member>) {
        let index = Java_init(forKeyPath: keyPath)
        Java_access(index)
    }

    public func willSet<Subject, Member>(_ subject: Subject, keyPath: KeyPath<Subject, Member>) {
        let index = Java_init(forKeyPath: keyPath)
        Java_update(index)
    }

    /// Trigger a single MutableStateBacking counter increment for Compose recomposition.
    /// Called from withObservationTracking's onChange handler.
    func triggerSingleUpdate() {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard Java_hasInitialized, Java_peer != nil else { return }
        Java_update(0)
    }

    private static let Java_stateClass = try? JClass(name: "skip/model/MutableStateBacking")
    private static let Java_state_init_methodID = Java_stateClass?.getMethodID(name: "<init>", sig: "()V")
    private static let Java_state_access_methodID = Java_stateClass?.getMethodID(name: "access", sig: "(I)V")
    private static let Java_state_update_methodID = Java_stateClass?.getMethodID(name: "update", sig: "(I)V")

    private var Java_peer: JObject?
    private var Java_hasInitialized = false

    private func Java_init(forKeyPath keyPath: AnyKeyPath) -> Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        if !Java_hasInitialized {
            Java_hasInitialized = true
            Java_peer = Java_initPeer()
        }
        guard Java_peer != nil else {
            return 0
        }
        return index(forKeyPath: keyPath)
    }

    private func Java_initPeer() -> JObject? {
        guard isJNIInitialized else {
            return nil
        }
        return jniContext {
            guard let cls = Self.Java_stateClass, let initMethod = Self.Java_state_init_methodID else {
                return nil
            }
            let ptr: JavaObjectPointer = try! cls.create(ctor: initMethod, options: [], args: [])
            return JObject(ptr)
        }
    }

    private func Java_access(_ index: Int) {
        guard isJNIInitialized, let peer = Java_peer else {
            return
        }
        jniContext {
            guard let accessMethod = Self.Java_state_access_methodID else {
                return
            }
            try! peer.call(method: accessMethod, options: [], args: [Int32(index).toJavaParameter(options: [])])
        }
    }

    private func Java_update(_ index: Int) {
        guard isJNIInitialized, let peer = Java_peer else {
            return
        }
        jniContext {
            guard let updateMethod = Self.Java_state_update_methodID else {
                return
            }
            try! peer.call(method: updateMethod, options: [], args: [Int32(index).toJavaParameter(options: [])])
        }
    }

    private var lock = os_unfair_lock()
    private var indexes: [AnyKeyPath: Int] = [:]

    private func index(forKeyPath keyPath: AnyKeyPath) -> Int {
        if let index = indexes[keyPath] {
            return index
        }
        let nextIndex = indexes.count
        indexes[keyPath] = nextIndex
        return nextIndex
    }
}


// MARK: - JNI exports for ViewObservation (skip-ui Kotlin object)
// These are called via JNI from the ViewObservation Kotlin object's external fun declarations.
// JNI naming convention: Java_<package>_<class>_<method> where dots become underscores.
// ViewObservation is in package skip.ui, so: Java_skip_ui_ViewObservation_<method>

#if os(Android)

@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
@_cdecl("Java_skip_ui_ViewObservation_nativeEnable")
func _jni_nativeEnable(_ env: OpaquePointer?, _ thiz: OpaquePointer?) {
    ObservationRecording.isEnabled = true
}

@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
@_cdecl("Java_skip_ui_ViewObservation_nativeStartRecording")
func _jni_nativeStartRecording(_ env: OpaquePointer?, _ thiz: OpaquePointer?) {
    ObservationRecording.startRecording()
}

@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
@_cdecl("Java_skip_ui_ViewObservation_nativeStopAndObserve")
func _jni_nativeStopAndObserve(_ env: OpaquePointer?, _ thiz: OpaquePointer?) {
    ObservationRecording.stopAndObserve()
}

#endif

#if os(Android) && !swift(>=6.3)
// Without this we get the crash on launch: 08-09 18:45:51.978 10431 10431 E AndroidRuntime: java.lang.UnsatisfiedLinkError: dlopen failed: cannot locate symbol "_ZN5swift9threading5fatalEPKcz" referenced by "/data/app/~~aevIacTPjMLuc5Cymf5l-A==/skip.droid.app--cf8i3s7JV9Ln9saNnThMg==/base.apk!/lib/arm64-v8a/libswiftObservation.so"...
// Seem like Swift/lib/Threading/Errors.cpp (https://github.com/swiftlang/swift/blob/3934f78ecdd53031ac40d68499f9ee046a5abe50/lib/Threading/Errors.cpp#L13) is missing
// Should be fixed by: https://github.com/swiftlang/swift/pull/77890
// Version-gated: auto-removes when Swift 6.3 ships the upstream fix.
@_cdecl("_ZN5swift9threading5fatalEPKcz")
public func swiftThreadingFatal() {
    // we need to do *something* here or the function will get stripped out in release mode
    print("swiftThreadingFatal")
}

#endif

#endif
