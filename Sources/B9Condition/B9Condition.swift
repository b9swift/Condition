/*
 B9Condition.swift

 Copyright © 2022 BB9z.
 https://github.com/b9swift/Condition

 The MIT License
 https://opensource.org/licenses/MIT
 */

@_exported import B9Action
import Foundation

/**
 Maintains a set of states that allows it to perform observation actions when the specific states are satisfied.

 Muilt-thread is supported. You can modify states on any thread. The observer will be triggered in its queue or use Condition's if not set, when the status meets.

 1. Observer actions are normally performed with satisfied states by checking the status again before execution. However, it is possible that the states has been changed in other thread just after the check, resulting an action is performed when the states not match the expectation.
 2. When changing state periodically in one thread and observer in another thread, the worst case is that the observer may never execute, as the status are set back while checking in the observer queue.

 It always has a delay between status changing and observer triggering.

 Instance must be hold with strong refrence, or it will be released and all observe will be canceled immediately. With one exception:

 - If there are actions being executed in other threads, this instance will be temporarily held.

 */
public final class Condition<T: SetAlgebra> {

    /// Create a new Condition instance
    ///
    /// - Parameter queue: A dispatch queue, use the main queue if not specified.
    public init(queue: DispatchQueue = .main) {
        self.queue = queue
    }

    /// The defualt queue. Observer action is perfromed in this queue if not specified.
    public let queue: DispatchQueue

    /// Returns whether current states meets the given flags.
    public func meets(_ flags: T) -> Bool {
        self.flags.isSuperset(of: flags)
    }

    /// Turn on flags.
    /// - Parameter flags: Flags needs turn on.
    public func set(on flags: T) {
        lock.lock()
        self.flags = self.flags.union(flags)
        flagsChange.set()
        lock.unlock()
    }

    /// Turn off flags.
    /// - Parameter flags: Flags needs turn off.
    public func set(off flags: T) {
        lock.lock()
        self.flags.subtract(flags)
        flagsChange.set()
        lock.unlock()
    }

    /// Add status observer that performs given action when status are satisfied.
    ///
    /// - Parameters:
    ///   - flags: Status to be satisfied
    ///   - action: Action performed if the status are satisfied.
    ///   - queue: Optional. The queue when the action is performed.
    ///   - autoRemove: Should remove the observer after action performed. No by default.
    /// - Returns: An object can used to remove observer. `Condition` strongly holds this return value until the observer is removed.
    @discardableResult
    public func observe(_ flags: T, action: Action, queue: DispatchQueue? = nil, autoRemove: Bool = false) -> AnyObject {
        let observer = Observer(flags, action)
        observer.shouldAutoRemove = autoRemove
        observer.queue = queue
        lock.lock()
        observers.append(observer)
        lock.unlock()
        return observer
    }

    /// Remove given observer.
    ///
    /// - Parameter observer: The value returned from the add observer method.
    public func remove(observer: AnyObject?) {
        guard let observer = observer else { return }
        lock.lock()
        defer { lock.unlock() }
        if let idx = observers.firstIndex(where: { $0 === observer }) {
            observers.remove(at: idx)
        }
    }

    /// Wait for the satisfied status then perform given action.
    ///
    /// - Parameters:
    ///   - flags: Status to be satisfied
    ///   - action: Action performed if the status are satisfied.
    ///   - timeout: Enable timeout when it is greater than 0. Observer will be discarded if times out.
    public func wait(_ flags: T, action: Action, timeout: TimeInterval = 0) {
        let observer = Observer(flags, action)
        observer.shouldAutoRemove = true
        appendAndCheck(observer: observer)
        if timeout > 0 {
            queue.asyncAfter(deadline: .now() + timeout) { [weak self, weak observer] in
                guard let sf = self, let observer = observer else { return }
                sf.remove(observer: observer)
            }
        }
    }

    // MARK: -

    internal var flags = T()
    internal var observers = [Observer]()
    /// flags 写保护，observers 读写保护
    private let lock = NSLock()

    private lazy var flagsChange = DelayAction(Action({ [weak self] in
        self?.onFlagsChange()
    }, reference: nil), delay: 0, queue: queue)

    private func onFlagsChange() {
        lock.lock()
        let observersSnapshot = observers
        lock.unlock()
        if observersSnapshot.isEmpty { return }
        for observer in observersSnapshot {
            if meets(observer.flags) {
                if !observer.hasCalledWhenMeet {
                    if let otherQueue = observer.queue {
                        otherQueue.async {
                            // 需临时保持实例
                            if self.meets(observer.flags) {
                                self.execute(observer: observer)
                            }
                        }
                    } else {
                        execute(observer: observer)
                    }
                }
            } else {
                if observer.hasCalledWhenMeet {
                    observer.hasCalledWhenMeet = false
                }
            }
        }
    }

    internal final class Observer: CustomDebugStringConvertible {
        let flags: T
        let action: Action
        var shouldAutoRemove = false
        var hasCalledWhenMeet = false
        var queue: DispatchQueue?

        init(_ flags: T, _ action: Action) {
            self.flags = flags
            self.action = action
        }

        internal var debugDescription: String {
            let properties: [(String, Any?)] = [("flags", flags), ("queue", queue), ("shouldAutoRemove", shouldAutoRemove), ("action", action)]
            let propertyDiscription = properties.compactMap { key, value in
                if let value = value {
                    return "\(key) = \(value)"
                }
                return nil
            }.joined(separator: ", ")
            return "<Observer \(Unmanaged.passUnretained(self).toOpaque()): \(propertyDiscription)>"
        }
    }

    private func execute(observer: Observer) {
        assert(meets(observer.flags))
        observer.action.perform(with: nil)
        observer.hasCalledWhenMeet = true
        if observer.shouldAutoRemove {
            remove(observer: observer)
        }
    }

    private func appendAndCheck(observer: Observer) {
        lock.lock()
        observers.append(observer)
        lock.unlock()
        (observer.queue ?? queue).async { [weak self, weak observer] in
            guard let sf = self, let observer = observer else { return }
            if sf.meets(observer.flags) {
                sf.execute(observer: observer)
            }
        }
    }
}

extension Condition: CustomDebugStringConvertible {
    public var debugDescription: String {
        let properties: [(String, Any?)] = [("flags", flags), ("queue", queue), ("observers", observers)]
        let propertyDiscription = properties.compactMap { key, value in
            if let value = value {
                return "\(key) = \(value)"
            }
            return nil
        }.joined(separator: ", ")
        return "<Condition \(Unmanaged.passUnretained(self).toOpaque()): \(propertyDiscription)>"
    }
}
