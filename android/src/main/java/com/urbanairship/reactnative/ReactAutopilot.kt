/* Copyright Urban Airship and Contributors */

package com.urbanairship.reactnative

import android.content.Context
import com.urbanairship.UAirship
import com.urbanairship.analytics.Extension
import com.urbanairship.android.framework.proxy.BaseAutopilot
import com.urbanairship.android.framework.proxy.Event
import com.urbanairship.android.framework.proxy.EventType
import com.urbanairship.android.framework.proxy.ProxyLogger
import com.urbanairship.android.framework.proxy.ProxyStore
import com.urbanairship.android.framework.proxy.events.EventEmitter
import com.urbanairship.embedded.AirshipEmbeddedInfo
import com.urbanairship.embedded.AirshipEmbeddedObserver
import com.urbanairship.json.JsonMap
import com.urbanairship.json.jsonMapOf
import com.urbanairship.reactnative.ManifestUtils.extenderClassName
import com.urbanairship.reactnative.ManifestUtils.isHeadlessJSTaskEnabledOnStart
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.launch

/**
 * Module's autopilot to customize Urban Airship.
 */
class ReactAutopilot : BaseAutopilot() {

    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())

    override fun onReady(context: Context, airship: UAirship) {
        ProxyLogger.info("Airship React Native version: %s, SDK version: %s", BuildConfig.AIRSHIP_MODULE_VERSION, UAirship.getVersion())

        val allowHeadlessJsTaskBeforeModule = context.isHeadlessJSTaskEnabledOnStart()
        ProxyLogger.debug("ALLOW_HEADLESS_JS_TASK_BEFORE_MODULE: $allowHeadlessJsTaskBeforeModule")

        if (allowHeadlessJsTaskBeforeModule) {
            scope.launch {
                EventEmitter.shared().pendingEventListener
                    .filter { !it.type.isForeground() }
                    .collect {
                        AirshipHeadlessEventService.startService(context)
                    }
            }
        }

        scope.launch {
            AirshipEmbeddedObserver(filter = { true }).embeddedViewInfoFlow.collect {
                EventEmitter.shared().addEvent(PendingEmbeddedUpdated(it))
            }
        }

        // Set our custom notification provider
        val notificationProvider = ReactNotificationProvider(context, airship.airshipConfigOptions)
        airship.pushManager.notificationProvider = notificationProvider

        airship.analytics.registerSDKExtension(Extension.REACT_NATIVE, BuildConfig.AIRSHIP_MODULE_VERSION)

        // Legacy extender
        val extender = createExtender(context)
        extender?.onAirshipReady(context, airship)
    }

    override fun onMigrateData(context: Context, proxyStore: ProxyStore) {
        DataMigrator(context).migrateData(proxyStore)
    }

    @Suppress("deprecation")
    private fun createExtender(context: Context): AirshipExtender? {
        val className = context.extenderClassName() ?: return null
        try {
            val extenderClass = Class.forName(className)
            return extenderClass.getDeclaredConstructor().newInstance() as AirshipExtender
        } catch (e: Exception) {
            ProxyLogger.error(e, "Unable to create extender: $className")
        }
        return null
    }
}

internal class PendingEmbeddedUpdated(pending: List<AirshipEmbeddedInfo>) : Event {
    override val type = EventType.PENDING_EMBEDDED_UPDATED

    override val body: JsonMap = jsonMapOf(
        "pending" to pending.map { jsonMapOf( "embeddedId" to it.embeddedId ) }
    )
}

