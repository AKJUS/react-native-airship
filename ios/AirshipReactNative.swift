/* Copyright Airship and Contributors */

import Foundation
import AirshipKit
import AirshipFrameworkProxy
import React

@objc
public class AirshipReactNative: NSObject {
    
    @objc
    public static let pendingEventsEventName = "com.airship.pending_events"

    @objc
    public static let overridePresentationOptionsEventName = "com.airship.ios.override_presentation_options"

    @objc
    public static let pendingEmbeddedUpdated = "com.airship.iax.pending_embedded_updated"

    private let serialQueue = AirshipAsyncSerialQueue()
    var lock = AirshipLock()
    var pendingPresentationRequests: [String: PresentationOptionsOverridesRequest] = [:]
    
    @objc
    public var overridePresentationOptionsEnabled: Bool = false {
        didSet {
            if (!overridePresentationOptionsEnabled) {
                lock.sync {
                    self.pendingPresentationRequests.values.forEach { request in
                        request.result(options: nil)
                    }
                    self.pendingPresentationRequests.removeAll()
                }
            }
        }
    }

    public static var proxy: AirshipProxy {
        AirshipProxy.shared
    }

    public static let version: String = "24.5.0"

    private let eventNotifier = EventNotifier()

    @objc
    public static let shared: AirshipReactNative = AirshipReactNative()

    @objc
    public func setNotifier(_ notifier: ((String, [String: Any]) -> Void)?) {
        self.serialQueue.enqueue { @MainActor in
            if let notifier = notifier {
                await self.eventNotifier.setNotifier {
                    notifier(AirshipReactNative.pendingEventsEventName, [:])
                }

                if AirshipProxyEventEmitter.shared.hasAnyEvents() {
                    await self.eventNotifier.notifyPendingEvents()
                }

                AirshipProxy.shared.push.presentationOptionOverrides = { request in
                    guard self.overridePresentationOptionsEnabled else {
                        request.result(options: nil)
                        return
                    }


                    guard
                        let requestPayload =  try? AirshipJSON.wrap(
                            request.pushPayload
                        ).unWrap()
                    else {
                        AirshipLogger.error("Failed to generate payload: \(request)")
                        request.result(options: nil)
                        return
                    }

                    let requestID = UUID().uuidString
                    self.lock.sync {
                        self.pendingPresentationRequests[requestID] = request
                    }
                    notifier(
                        AirshipReactNative.overridePresentationOptionsEventName,
                        [
                            "pushPayload": requestPayload,
                            "requestId": requestID
                        ]
                    )
                }
            } else {
                await self.eventNotifier.setNotifier(nil)
                AirshipProxy.shared.push.presentationOptionOverrides = nil

                self.lock.sync {
                    self.pendingPresentationRequests.values.forEach { request in
                        request.result(options: nil)
                    }
                    self.pendingPresentationRequests.removeAll()
                }
            }
        }
    }
    
    @objc
    public func presentationOptionOverridesResult(requestID: String, presentationOptions: [String]?) {
        lock.sync {
            pendingPresentationRequests[requestID]?.result(optionNames: presentationOptions)
            pendingPresentationRequests[requestID] = nil
        }
    }
    

    @MainActor
    func onLoad(
        launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) {
        AirshipProxy.shared.delegate = self
        try? AirshipProxy.shared.attemptTakeOff(launchOptions: launchOptions)

        Task {
            let stream = AirshipProxyEventEmitter.shared.pendingEventAdded
            for await _ in stream {
                await self.eventNotifier.notifyPendingEvents()
            }
        }
    }

    @objc
    public func onListenerAdded(eventName: String) {
        guard let type = try? AirshipProxyEventType.fromReactName(eventName) else {
            return
        }

        Task {
            if (await AirshipProxyEventEmitter.shared.hasEvent(type: type)) {
                await self.eventNotifier.notifyPendingEvents()
            }
        }
    }

    @objc
    public func takePendingEvents(eventName: String) async -> [Any] {
        guard let type = try? AirshipProxyEventType.fromReactName(eventName) else {
            return []
        }

        return await AirshipProxyEventEmitter.shared.takePendingEvents(
            type: type
        ).compactMap {
            do {
                return try $0.body.unwrapped()
            } catch {
                AirshipLogger.error("Failed to unwrap event body \($0) \(error)")
                return nil
            }
        }
    }


    @objc
    @MainActor
    public func attemptTakeOff(
        launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    )  {
        try? AirshipProxy.shared.attemptTakeOff(launchOptions: launchOptions)
    }
}

// Airship
public extension AirshipReactNative {
    @objc
    @MainActor
    func takeOff(
        json: Any,
        launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) throws -> NSNumber {
        return try NSNumber(
            value: AirshipProxy.shared.takeOff(
                json: json,
                launchOptions: launchOptions
            )
        )
    }

    @objc
    func isFlying() -> Bool {
        return Airship.isFlying
    }

}

// Channel
@objc
public extension AirshipReactNative {
    
    @objc
    func channelAddTag(_ tag: String) throws {
        return try AirshipProxy.shared.channel.addTags([tag])
    }

    @objc
    func channelRemoveTag(_ tag: String) throws {
        return try AirshipProxy.shared.channel.removeTags([tag])
    }
    
    @objc
    func channelEditTags(json: Any) throws {
        let operations = try JSONDecoder().decode(
            [TagOperation].self,
            from: try AirshipJSONUtils.data(json)
        )
        try AirshipProxy.shared.channel.editTags(
            operations: operations
        )
    }

    @objc
    func channelEnableChannelCreation() throws -> Void {
        try AirshipProxy.shared.channel.enableChannelCreation()
    }

    @objc
    func channelGetTags() throws -> [String] {
        return try AirshipProxy.shared.channel.tags
    }

    @objc
    func channelGetSubscriptionLists() async throws -> [String] {
        return try await AirshipProxy.shared.channel.fetchSubscriptionLists()
    }

    @objc
    func channelGetChannelIdOrEmpty() throws -> String {
        return try AirshipProxy.shared.channel.channelID ?? ""
    }

    @objc
    func channelWaitForChannelId() async throws -> String {
        return try await AirshipProxy.shared.channel.waitForChannelID()
    }

    @objc
    func channelEditTagGroups(json: Any) throws {
        let operations = try JSONDecoder().decode(
            [TagGroupOperation].self,
            from: try AirshipJSONUtils.data(json)
        )
        try AirshipProxy.shared.channel.editTagGroups(operations: operations)
    }

    @objc
    func channelEditAttributes(json: Any) throws {
        let operations = try JSONDecoder().decode(
            [AttributeOperation].self,
            from: try AirshipJSONUtils.data(json)
        )
        try AirshipProxy.shared.channel.editAttributes(operations: operations)
    }

    @objc
    func channelEditSubscriptionLists(json: Any) throws {
        try AirshipProxy.shared.channel.editSubscriptionLists(json: json)
    }
}

// Push
@objc
public extension AirshipReactNative {
    @objc
    func pushSetUserNotificationsEnabled(
        _ enabled: Bool
    ) throws -> Void {
        try AirshipProxy.shared.push.setUserNotificationsEnabled(enabled)
    }

    @objc
    func pushIsUserNotificationsEnabled() throws -> NSNumber {
        return try NSNumber(
            value: AirshipProxy.shared.push.isUserNotificationsEnabled()
        )
    }

    @objc
    func pushEnableUserNotifications(options: Any?) async throws -> Bool {
        let args: EnableUserPushNotificationsArgs? = if let options {
            try AirshipJSON.wrap(options).decode()
        } else {
            nil
        }
        return try await AirshipProxy.shared.push.enableUserPushNotifications(args: args)
    }

    @objc
    @MainActor
    func pushGetRegistrationTokenOrEmpty() throws -> String {
        return try AirshipProxy.shared.push.getRegistrationToken() ?? ""
    }

    @objc
    @MainActor
    func pushSetNotificationOptions(
        names:[String]
    ) throws {
        try AirshipProxy.shared.push.setNotificationOptions(names: names)
    }

    @objc
    @MainActor
    func pushSetForegroundPresentationOptions(
        names:[String]
    ) throws {
        try AirshipProxy.shared.push.setForegroundPresentationOptions(
            names: names
        )
    }

    @objc
    func pushGetNotificationStatus() async throws -> [String: Any] {
        return try await AirshipProxy.shared.push.notificationStatus.unwrapped()
    }

    @objc
    func pushSetAutobadgeEnabled(_ enabled: Bool) throws {
        try AirshipProxy.shared.push.setAutobadgeEnabled(enabled)
    }

    @objc
    func pushIsAutobadgeEnabled() throws -> NSNumber {
        return try NSNumber(
            value: AirshipProxy.shared.push.isAutobadgeEnabled()
        )
    }

    @objc
    @MainActor
    func pushSetBadgeNumber(_ badgeNumber: Double) async throws {
        try await AirshipProxy.shared.push.setBadgeNumber(Int(badgeNumber))
    }

    @objc
    @MainActor
    func pushGetBadgeNumber() throws -> NSNumber {
        return try NSNumber(
            value: AirshipProxy.shared.push.getBadgeNumber()
        )
    }

    @objc
    func pushGetAuthorizedNotificationStatus() throws -> String {
        return try AirshipProxy.shared.push.getAuthroizedNotificationStatus()
    }

    @objc
    func pushGetAuthorizedNotificationSettings() throws -> [String] {
        return try AirshipProxy.shared.push.getAuthorizedNotificationSettings()
    }

    @objc
    func pushClearNotifications() {
        AirshipProxy.shared.push.clearNotifications()
    }

    @objc
    func pushClearNotification(_ identifier: String) {
        AirshipProxy.shared.push.clearNotification(identifier)
    }

    @objc
    func pushGetActiveNotifications() async throws -> [[String: Any]] {
        return try await AirshipProxy.shared.push.getActiveNotifications().map { try $0.unwrapped() }
    }
}

// Actions
@objc
public extension AirshipReactNative {
    func actionsRun(action: [String: Any]) async throws-> Any? {
        guard let name = action["name"] as? String else {
            throw AirshipErrors.error("missing name")
        }

        return try await AirshipProxy.shared.action.runAction(
            name,
            value: action["value"] is NSNull ? nil : try AirshipJSON.wrap(action["value"])
        )
    }
}

// Analytics
@objc
public extension AirshipReactNative {

    @MainActor
    func analyticsTrackScreen(_ screen: String?) throws {
        try AirshipProxy.shared.analytics.trackScreen(screen)
    }

    func analyticsAssociateIdentifier(_ identifier: String?, key: String) throws {
        try AirshipProxy.shared.analytics.associateIdentifier(
            identifier: identifier,
            key: key
        )
    }

    func addCustomEvent(_ json: Any) throws {
        try AirshipProxy.shared.analytics.addEvent(json)
    }

    @objc
    @MainActor
    func analyticsGetSessionId() throws -> String {
        try AirshipProxy.shared.analytics.getSessionID().lowercased()
    }
}

// Contact
@objc
public extension AirshipReactNative {

    @objc
    func contactIdentify(_ namedUser: String?) throws {
        try AirshipProxy.shared.contact.identify(namedUser ?? "")
    }

    @objc
    func contactReset() throws {
        try AirshipProxy.shared.contact.reset()
    }

    @objc
    func contactNotifyRemoteLogin() throws {
        try AirshipProxy.shared.contact.notifyRemoteLogin()
    }

    @objc
    func contactGetNamedUserIdOrEmtpy() async throws -> String {
        return try await AirshipProxy.shared.contact.namedUserID ?? ""
    }

    @objc
    func contactGetSubscriptionLists() async throws -> [String: [String]] {
        return try await AirshipProxy.shared.contact.getSubscriptionLists()
    }

    @objc
    func contactEditTagGroups(json: Any) throws {
        let operations = try JSONDecoder().decode(
            [TagGroupOperation].self,
            from: try AirshipJSONUtils.data(json)
        )
        try AirshipProxy.shared.contact.editTagGroups(operations: operations)
    }

    @objc
    func contactEditAttributes(json: Any) throws {
        let operations = try JSONDecoder().decode(
            [AttributeOperation].self,
            from: try AirshipJSONUtils.data(json)
        )
        try AirshipProxy.shared.contact.editAttributes(operations: operations)
    }

    @objc
    func contactEditSubscriptionLists(json: Any) throws {
        let operations = try JSONDecoder().decode(
            [ScopedSubscriptionListOperation].self,
            from: try AirshipJSONUtils.data(json)
        )
        try AirshipProxy.shared.contact.editSubscriptionLists(operations: operations)
    }
}

// InApp
@objc
public extension AirshipReactNative {
    @objc
    @MainActor
    func inAppIsPaused() throws -> NSNumber {
        return try NSNumber(
            value: AirshipProxy.shared.inApp.isPaused()
        )
    }

    @objc
    @MainActor
    func inAppSetPaused(_ paused: Bool) throws {
        try AirshipProxy.shared.inApp.setPaused(paused)
    }

    @objc
    @MainActor
    func inAppSetDisplayInterval(milliseconds: Double) throws {
        try AirshipProxy.shared.inApp.setDisplayInterval(milliseconds: Int(milliseconds))
    }

    @objc
    @MainActor
    func inAppGetDisplayInterval() throws -> NSNumber {
        return try NSNumber(
            value: AirshipProxy.shared.inApp.getDisplayInterval()
        )
    }

    @objc
    func inAppResendPendingEmbeddedEvent() {
        AirshipProxy.shared.inApp.resendLastEmbeddedEvent()
    }
}

// Locale
@objc
public extension AirshipReactNative {
    @objc
    func localeSetLocaleOverride(localeIdentifier: String?) throws {
        try AirshipProxy.shared.locale.setCurrentLocale(localeIdentifier)
    }

    @objc
    func localeClearLocaleOverride() throws {
        try AirshipProxy.shared.locale.clearLocale()
    }

    @objc
    func localeGetLocale() throws -> String {
        return try AirshipProxy.shared.locale.currentLocale
    }
}

// Message Center
@objc
public extension AirshipReactNative {
    @objc
    func messageCenterGetUnreadCount() async throws -> Double {
        return try await Double(AirshipProxy.shared.messageCenter.unreadCount)
    }

    @objc
    func messageCenterGetMessages() async throws -> Any {
        let messages = try await AirshipProxy.shared.messageCenter.messages
        return try AirshipJSON.wrap(messages).unWrap() as Any
    }

    @objc
    func messageCenterMarkMessageRead(messageId: String) async throws  {
        try await AirshipProxy.shared.messageCenter.markMessageRead(
            messageID: messageId
        )
    }

    @objc
    func messageCenterDeleteMessage(messageId: String) async throws  {
        try await AirshipProxy.shared.messageCenter.deleteMessage(
            messageID: messageId
        )
    }

    @MainActor @objc
    func messageCenterDismiss() throws  {
        return try AirshipProxy.shared.messageCenter.dismiss()
    }

    @MainActor @objc
    func messageCenterDisplay(messageId: String?) throws  {
        try AirshipProxy.shared.messageCenter.display(messageID: messageId)
    }

    @MainActor @objc
    func messageCenterShowMessageView(messageId: String) throws  {
        try AirshipProxy.shared.messageCenter.showMessageView(messageID: messageId)
    }

    @MainActor @objc
    func messageCenterShowMessageCenter(messageId: String?) throws  {
        try AirshipProxy.shared.messageCenter.showMessageCenter(messageID: messageId)
    }

    @objc
    func messageCenterRefresh() async throws  {
        try await AirshipProxy.shared.messageCenter.refresh()
    }

    @objc
    @MainActor
    func messageCenterSetAutoLaunchDefaultMessageCenter(autoLaunch: Bool) {
        AirshipProxy.shared.messageCenter.setAutoLaunchDefaultMessageCenter(autoLaunch)
    }
}

// Preference Center
@objc
public extension AirshipReactNative {
    @objc
    @MainActor
    func preferenceCenterDisplay(preferenceCenterId: String) throws  {
        try AirshipProxy.shared.preferenceCenter.displayPreferenceCenter(
            preferenceCenterID: preferenceCenterId
        )
    }

  @objc
  func preferenceCenterGetConfig(preferenceCenterId: String) async throws -> AnyHashable? {
        return try await AirshipProxy.shared.preferenceCenter.getPreferenceCenterConfig(
            preferenceCenterID: preferenceCenterId
        ).unWrap()
    }

    @objc
    @MainActor
    func preferenceCenterAutoLaunchDefaultPreferenceCenter(
        preferenceCenterId: String,
        autoLaunch: Bool
    ) {
        AirshipProxy.shared.preferenceCenter.setAutoLaunchPreferenceCenter(
            autoLaunch,
            preferenceCenterID: preferenceCenterId
        )
    }
}

// Privacy Manager
@objc
public extension AirshipReactNative {
    @objc
    func privacyManagerSetEnabledFeatures(features: [String]) throws  {
        try AirshipProxy.shared.privacyManager.setEnabled(featureNames: features)
    }

    @objc
    func privacyManagerGetEnabledFeatures() throws -> [String] {
        return try AirshipProxy.shared.privacyManager.getEnabledNames()
    }

    @objc
    func privacyManagerEnableFeature(features: [String]) throws  {
        try AirshipProxy.shared.privacyManager.enable(featureNames: features)
    }

    @objc
    func privacyManagerDisableFeature(features: [String]) throws  {
        try AirshipProxy.shared.privacyManager.disable(featureNames: features)
    }

    @objc
    func privacyManagerIsFeatureEnabled(features: [String]) throws -> NSNumber  {
        return try NSNumber(
            value: AirshipProxy.shared.privacyManager.isEnabled(featuresNames: features)
        )
    }
}



// Feature Flag Manager
@objc
public extension AirshipReactNative {
    @objc
    func featureFlagManagerFlag(flagName: String, useResultCache: Bool) async throws -> Any  {
        let result = try await AirshipProxy.shared.featureFlagManager.flag(name: flagName, useResultCache: useResultCache)
        return try AirshipJSON.wrap(result).unWrap() as Any
    }

    @objc
    func featureFlagManagerTrackInteracted(flag: Any) throws {
        let flag: FeatureFlagProxy = try AirshipJSON.wrap(flag).decode()
        try AirshipProxy.shared.featureFlagManager.trackInteraction(flag: flag)
    }

    @objc
    func featureFlagManagerResultCacheGetFlag(name: String) async throws -> Any {
        let result = try await AirshipProxy.shared.featureFlagManager.resultCache.flag(name: name)
        return try AirshipJSON.wrap(result).unWrap() as Any
    }

    @objc
    func featureFlagManagerResultCacheSetFlag(flag: Any, ttl: NSNumber) async throws {
        let flag: FeatureFlagProxy = try AirshipJSON.wrap(flag).decode()
        try await AirshipProxy.shared.featureFlagManager.resultCache.cache(
            flag: flag,
            ttl: TimeInterval(ttl.uint64Value/1000)
        )
    }

    @objc
    func featureFlagManagerResultCacheRemoveFlag(name: String) async throws {
        try await AirshipProxy.shared.featureFlagManager.resultCache.removeCachedFlag(name: name)
    }
}


// Live Activity
@objc
public extension AirshipReactNative {

    @objc
    func liveActivityList(options: Any) async throws -> Any  {
        if #available(iOS 16.1, *) {
            let result = try await LiveActivityManager.shared.list(try AirshipJSON.wrap(options).decode())
            return try AirshipJSON.wrap(result).unWrap() as Any
        } else {
            throw AirshipErrors.error("Not available before 16.1")
        }
    }

    @objc
    func liveActivityListAll() async throws -> Any  {
        if #available(iOS 16.1, *) {
            let result = try await LiveActivityManager.shared.listAll()
            return try AirshipJSON.wrap(result).unWrap() as Any
        } else {
            throw AirshipErrors.error("Not available before 16.1")
        }
    }

    @objc
    func liveActivityStart(options: Any) async throws -> Any  {
        if #available(iOS 16.1, *) {
            let result = try await LiveActivityManager.shared.start(try AirshipJSON.wrap(options).decode())
            return try AirshipJSON.wrap(result).unWrap() as Any
        } else {
            throw AirshipErrors.error("Not available before 16.1")
        }
    }

    @objc
    func liveActivityUpdate(options: Any) async throws -> Void  {
        if #available(iOS 16.1, *) {
            try await LiveActivityManager.shared.update(try AirshipJSON.wrap(options).decode())
        } else {
            throw AirshipErrors.error("Not available before 16.1")
        }
    }

    @objc
    func liveActivityEnd(options: Any) async throws -> Void  {
        if #available(iOS 16.1, *) {
            try await LiveActivityManager.shared.end(try AirshipJSON.wrap(options).decode())
        } else {
            throw AirshipErrors.error("Not available before 16.1")
        }
    }
}

extension AirshipReactNative: AirshipProxyDelegate {
    public func migrateData(store: ProxyStore) {
        ProxyDataMigrator().migrateData(store: store)
    }

    public func loadDefaultConfig() -> AirshipConfig {
        let path = Bundle.main.path(
            forResource: "AirshipConfig",
            ofType: "plist"
        )

        var config: AirshipConfig?
        if let path = path, FileManager.default.fileExists(atPath: path) {
            do {
                config = try AirshipConfig.default()
            } catch {
                AirshipLogger.error("Failed to load config from plist: \(error)")
            }
        }

        return config ?? AirshipConfig()
    }

    public func onAirshipReady() {
        Airship.analytics.registerSDKExtension(
            .reactNative,
            version: AirshipReactNative.version
        )
    }
}


private actor EventNotifier {
    private var notifier: (() -> Void)?
    func setNotifier(_ notifier: (() -> Void)?) {
        self.notifier = notifier
    }

    func notifyPendingEvents() {
        self.notifier?()
    }
}


extension AirshipProxyEventType {
    private static let nameMap: [String: AirshipProxyEventType] = [
        "com.airship.deep_link": .deepLinkReceived,
        "com.airship.channel_created": .channelCreated,
        "com.airship.push_token_received": .pushTokenReceived,
        "com.airship.message_center_updated": .messageCenterUpdated,
        "com.airship.display_message_center": .displayMessageCenter,
        "com.airship.display_preference_center": .displayPreferenceCenter,
        "com.airship.notification_response": .notificationResponseReceived,
        "com.airship.push_received": .pushReceived,
        "com.airship.notification_status_changed": .notificationStatusChanged,
        "com.airship.authorized_notification_settings_changed": .authorizedNotificationSettingsChanged,
        "com.airship.pending_embedded_updated": .pendingEmbeddedUpdated,
        "com.airship.live_activities_updated": .liveActivitiesUpdated
    ]

    public static func fromReactName(_ name: String) throws -> AirshipProxyEventType {
        guard let type = AirshipProxyEventType.nameMap[name] else {
            throw AirshipErrors.error("Invalid type: \(self)")
        }

        return type
    }
}


fileprivate extension Encodable {
    func unwrapped<T>() throws -> T {
        guard let value = try AirshipJSON.wrap(self).unWrap() as? T else {
            throw AirshipErrors.error("Failed to unwrap codable")
        }
        return value
    }
}
