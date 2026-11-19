<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="../assets/dynarium-logo-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="../assets/dynarium-logo-light.svg">
    <img alt="Dynarium — Máquinas virtuales Android 17 en iOS" src="../assets/dynarium-logo-light.svg" width="460">
  </picture>
</p>

<p align="center">
  <a href="https://github.com/userlethekhoi/dynarium/releases"><img alt="Latest Release" src="https://img.shields.io/github/v/release/userlethekhoi/dynarium?style=flat-square&color=22B867"></a>
  <img alt="iOS 16.0 – 27+" src="https://img.shields.io/badge/iOS-16.0%20--%2027%2B-111318?style=flat-square">
  <a href="../../LICENSE"><img alt="License: GPL-2.0-or-later" src="https://img.shields.io/badge/License-GPL--2.0--or--later-303C4E?style=flat-square"></a>
</p>

<p align="center">
  <a href="../../README.md">English</a> ·
  <a href="README.vi.md">Tiếng Việt</a> ·
  <a href="README.zh-CN.md">简体中文</a> ·
  <a href="README.ja.md">日本語</a> ·
  <a href="README.ko.md">한국어</a> ·
  <strong>Español</strong>
</p>

---

Dynarium es un hipervisor multi-VM de Android para iPhone y iPad (**iOS 16.0 – iOS 27+**). Ejecuta **Android 17 (LineageOS 24)** sobre User-Mode Linux (`6.18 LTS`) y el Gadget Engine de [`imxieyi/Kernarium`](https://github.com/imxieyi/Kernarium).

En lugar de empaquetar una imagen de sistema de ~1 GB dentro del `.ipa`, Dynarium sigue un enfoque tipo VMware: el binario ocupa ~22–38 MiB, descargas o importas las ROM cuando las necesitas y ejecutas varias máquinas virtuales aisladas compartiendo el mismo `system.img` de solo lectura mediante clonación copy-on-write de APFS (`clonefile`).

## Descarga y elección de edición `.ipa`

Cada publicación en GitHub incluye dos archivos `.ipa` sin firmar listos para sideload (con entitlements aplicados vía `ldid`):

| Paquete `.ipa` | Dispositivos recomendados | Motor gráfico | Tamaño |
| :--- | :--- | :--- | :--- |
| `Dynarium-v<version>-Metal4-iOS26.ipa` | **Recomendado para iOS 26 / 27+** (chip A14 / M1 o superior) | Vulkan 1.4 / GLES 3.2 por hardware (`KosmicKrisp + Mesa Zink`) | ~22 MiB |
| `Dynarium-v<version>.ipa` | **Universal iOS 16.0 – 27+** (todos los Apple Silicon) | CPU `Mesa softpipe` (`DRAW_USE_LLVM=0`, sin JIT); cambia a `llvmpipe` si hay JIT | ~38 MiB |

Descarga ambos paquetes y `SHA256SUMS.txt` desde [GitHub Releases](https://github.com/userlethekhoi/dynarium/releases).

## Inicio rápido

1. Instala el `.ipa` correspondiente a tu versión de iOS mediante **TrollStore**, **AltStore** o **SideStore**.
2. En la pestaña de **ROMs (Kho ROM)** descarga LineageOS 24 (Android 17) con un toque, introduce una URL personalizada o importa un archivo `.tar.gz` / `.tar.zst` desde Archivos.
3. En la pestaña de **VMs (Máy ảo)** pulsa **+** para crear una máquina virtual (CPU, RAM y escala se ajustan automáticamente según `os_proc_available_memory()`) y pulsa Iniciar.
4. Usa la barra flotante inferior durante la sesión para abrir la consola serie, activar el teclado, instalar `.apk` o paquetes divididos `.apks`/`.apkm`, abrir Picture-in-Picture (PiP) o activar **AFK Eco Mode**.

## Qué incluye

- **ROMs separadas y clonación APFS:** Descomprime archivos `.tar.gz`, `.tar.zst` y `.tar` saltando bloques vacíos (`F_PUNCHHOLE`) con verificación SHA-256. Clonar una VM utiliza APFS `clonefile` sin duplicar espacio físico al instante.
- **Protección Anti-Jetsam:** Consulta el límite real de memoria del proceso y ajusta RAM, vCPUs y resolución (1x o Retina). Si una VM existente supera el margen seguro, ofrece optimizar la configuración en un toque antes de arrancar.
- **Progreso de arranque en vivo y diagnóstico:** Muestra las cuatro etapas de inicio del kernel y Android con cronómetro en lugar de una pantalla negra vacía, e interpreta `session.record` si iOS cerró la sesión anterior.
- **Instalador directo de APK y Split APK (VSOCK ADB):** Se conecta por VSOCK interno (`puerto 5555`) usando claves RSA-2048 por máquina guardadas en Keychain. Compatible con `.apk` individuales, conjuntos `.apks` / `.apkm` / `.zip` (`pm install-create`) y reenvío ADB por Wi-Fi.
- **Suite PiP y AFK Eco:** Picture-in-Picture compatible desde iOS 16+ (`AVSampleBufferDisplayLayer`), reducción de carga en segundo plano y pantalla negra OLED (`#000000`).

## Notas y limitaciones

- **El primer arranque tarda más:** Crear y formatear `data.img` (`f2fs`) la primera vez toma alrededor de **45–90 segundos** antes de mostrar la animación de Android.
- **Sideload con Apple ID gratuito:** Los certificados que eliminan `increased-memory-limit` limitan el proceso a unos `~2.0–2.3 GiB`. En esos dispositivos (o modelos de 4 GiB), mantén Retina desactivado y la RAM en `1 GiB`.
- **iOS 26 / 27+ en chip A14/M1 o superior:** Usa `Metal4-iOS26` siempre que tu dispositivo sea compatible; rinde mejor y consume menos RAM que el renderizado por CPU.

## Compilación en macOS (XcodeGen)

1. Descarga o extrae las dependencias precompiladas de `deps-ios16-latest` en `.build/dependencies` (o ejecuta `dependencies/build-ios-*.sh` y `dependencies/build-apple-gpu.sh`).
2. Compila `KernariumRuntime`:
   ```sh
   cmake --preset kernarium-ios-device-android
   cmake --build --preset kernarium-ios-device-android
   ```
3. Empaqueta los XCFrameworks (`--tier ios16-universal` o `--tier ios26-metal4`):
   ```sh
   ./Dynarium/scripts/package-dynarium-frameworks.sh --tier ios16-universal
   ```
4. Genera el proyecto de Xcode desde `Dynarium/project.yml`:
   ```sh
   (CDPATH= cd -- Dynarium && xcodegen generate)
   ```

## Créditos y licencia

Dynarium está construido sobre el runtime y trabajo de kernel de [`imxieyi/Kernarium`](https://github.com/imxieyi/Kernarium) (Yi Xie) e inspirado en el intérprete de [`ish-app/ish`](https://github.com/ish-app/ish). Consulta [`CREDITS.md`](../../CREDITS.md) para ver los avisos completos.

Distribuido bajo licencia **`GPL-2.0-or-later`** ([`LICENSE`](../../LICENSE)), excepto el código de superposición Android bajo **`Apache-2.0`** y los parches de terceros en [`LICENSES/`](../../LICENSES/).
