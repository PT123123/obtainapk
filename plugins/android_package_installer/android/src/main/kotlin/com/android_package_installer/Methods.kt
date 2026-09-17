package com.android_package_installer

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import android.util.Log

internal class MethodCallHandler(private val installer: Installer) : MethodChannel.MethodCallHandler {
    companion object {
        lateinit var callResult: MethodChannel.Result
        fun resultSuccess(data: Any) {
            try {
                callResult.success(data)
            } catch (_: IllegalStateException) {
                // Reply already submitted from a previous session commit intent
            }
        }

        fun nothing() {
            callResult.notImplemented()
        }

        /*
        fun resultError(s0: String, s1: String, o: Any) {
            callResult.error(s0, s1, o)
        }
        */
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        callResult = result
        when (call.method) {
            "installApk" -> {
                try {
                    val args = call.arguments
                    val apkFilePaths: Array<String>
                    val silent: Boolean
                    if (args is Map<*, *>) {
                        apkFilePaths = (args["apkFilePaths"] as String)
                            .split(",").map { it.trim() }.toTypedArray()
                        silent = args["silent"] as? Boolean ?: true
                    } else {
                        // Backwards compatibility: plain comma-joined path string.
                        apkFilePaths = args.toString().split(",").map { it.trim() }.toTypedArray()
                        silent = true
                    }
                    installer.installPackage(apkFilePaths, silent)
                } catch (e: Exception) {
                    Log.e("E0", e.toString())
                    resultSuccess(installStatusUnknown)
                }
            }
            else -> {
                nothing()
            }
        }
    }
}
