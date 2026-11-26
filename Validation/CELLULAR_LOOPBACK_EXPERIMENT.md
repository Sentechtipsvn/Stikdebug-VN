# 4G loopback probe — StikDebug VN experimental build

This is **not** a confirmed fix. The normal 10.7.0.1 Remote Pairing endpoint is tried first. Only when its pairing-provider creation fails and the device uses the default local VPN endpoint will the app try 127.0.0.1 on the **same discovered Remote Pairing port**. Existing route calculations, background behavior, confirmation dialogs and working Wi-Fi connections are unchanged.

The probe may fail because iOS can refuse same-device Remote Pairing. It cannot switch Cellular Data, override iOS routes or modify LocalDevVPN's NetworkExtension configuration.

Validation on iPhone 11 / iOS 18.7.8:
1. Back up the current app data, pairing file and routes before replacing the installed IPA. Never uninstall the stable app unless its data is backed up.
2. Connect LocalDevVPN with Wi-Fi disabled, Cellular Data on, and do **not** enable Airplane Mode.
3. Try setting a fixed simulated coordinate and starting a route.
4. Open Console and report the lines containing **Location Remote Pairing**, **Cellular loopback probe**, or **Location remote server handshake**. Do not share pairing files or credentials.
5. Verify whether Google Maps receives a moving simulated coordinate **without ever turning Cellular Data off**. Only that would count as a successful direct-4G test.
6. If unsuccessful, return to the existing verified workaround and keep this branch separate from production.

Tests in GitHub Actions validate Swift compilation and existing route/controller behavior, not iOS cellular routing.
