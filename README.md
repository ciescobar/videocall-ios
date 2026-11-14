# MI-DRIVER para iPad y iPhone

App nativa de validación para llamadas con Android y registro facial local guiado. Versión **0.1.4, compilación 5**, visible en pantalla. Identidad gráfica de Monitoreo Inteligente, captura automática más flexible y **USER TEST** después de identificarse: dos coincidencias con el perfil local muestran **USUARIO IDENTIFICADO**.

Estado: compilación Xcode ARM64 y 61 comprobaciones Swift aprobadas en [GitHub Actions](https://github.com/ciescobar/videocall-ios/actions/runs/43648522903), código a3b8d4f. IPA generado sin firma: `MI-DRIVER-iPad-0.1.4-sin-firma.ipa`. La instalación de esta actualización y la prueba con rostros reales están pendientes. La comprobación facial es experimental; no acredita identidad certificada ni resistencia a fotos o videos. Las plantillas permanecen cifradas en el dispositivo. No se incluyen datos biométricos de personas en este repositorio.

Consultar [novedades y validación vigente](Apple/NOVEDADES-0.1.4.txt), [instrucciones](Apple/LEEME-PRIMERO.txt) y [historial](Apple/VALIDACION-IPAD.txt).

## Comprobar compilación

En Actions, ejecutar manualmente **Comprobar VideoCall iOS**. El flujo usa un Mac estándar y compila sin firma. El resultado no se puede instalar en un iPad real hasta resolver la firma de Apple.

Los componentes de terceros conservan sus licencias en los recursos de la app.

El botón **Volver a matricular** repite frontal → arriba → abajo → izquierda → derecha y conserva el perfil anterior hasta guardar las cinco capturas. Cancelar descarta el reemplazo pendiente.
