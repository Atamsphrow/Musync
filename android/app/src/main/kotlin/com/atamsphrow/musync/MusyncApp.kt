package com.atamsphrow.musync

import android.app.Application
import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Handler
import android.os.Looper

/// Application : vit tant que le processus vit.
///
/// Y est branchée la détection des écouteurs (jack, USB, Bluetooth) via
/// `AudioManager.registerAudioDeviceCallback`. Un BroadcastReceiver déclaré
/// dans le manifest ne reçoit plus `ACTION_HEADSET_PLUG` depuis Android 8 :
/// il faut un enregistrement dynamique, donc un processus vivant.
///
/// Quand un casque apparaît (transition absent → présent), l'événement part
/// vers Dart (`headphonesConnected`), qui exécute le déclencheur configuré —
/// seulement si rien ne joue déjà. Si l'app a été tuée, rien ne se passe :
/// pas de service permanent juste pour guetter une prise jack.
///
/// Le branchement initial au démarrage ne déclenche rien : sinon chaque
/// ouverture de l'app avec des écouteurs déjà branchés lancerait de la
/// musique par surprise.
class MusyncApp : Application() {
    private var headphonesPresent = false
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onCreate() {
        super.onCreate()
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        headphonesPresent = hasHeadset(audioManager)
        // minSdk 26, registerAudioDeviceCallback existe depuis l'API 23.
        audioManager.registerAudioDeviceCallback(
            object : AudioManager.AudioDeviceCallback() {
                override fun onAudioDevicesAdded(added: Array<AudioDeviceInfo>) =
                    onDevicesChanged(audioManager)

                override fun onAudioDevicesRemoved(removed: Array<AudioDeviceInfo>) =
                    onDevicesChanged(audioManager)
            },
            mainHandler,
        )
    }

    private fun onDevicesChanged(audioManager: AudioManager) {
        val now = hasHeadset(audioManager)
        val plugged = now && !headphonesPresent
        headphonesPresent = now
        if (plugged) {
            // Le canal est posé par MainActivity sur le moteur audio_service ;
            // s'il n'est pas encore prêt, l'événement est perdu sans bruit —
            // Dart réarme de toute façon à chaque démarrage.
            MainActivity.schedulerChannel?.invokeMethod("headphonesConnected", null)
        }
    }

    private fun hasHeadset(audioManager: AudioManager): Boolean {
        return audioManager
            .getDevices(AudioManager.GET_DEVICES_OUTPUTS)
            .any { it.type in headsetTypes }
    }

    private companion object {
        val headsetTypes = setOf(
            AudioDeviceInfo.TYPE_WIRED_HEADSET,
            AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
            AudioDeviceInfo.TYPE_USB_HEADSET,
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
            AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
            AudioDeviceInfo.TYPE_BLE_HEADSET,
        )
    }
}
