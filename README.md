# VideoCall para iPad y iPhone

Primera versión nativa de validación para llamadas con Android y registro facial local guiado.

Estado: compilación Xcode ARM64 aprobada en [GitHub Actions](https://github.com/ciescobar/videocall-ios/actions/runs/43632351817), código 557e6de. IPA generado sin firma; instalación y pruebas físicas pendientes. La comprobación facial es experimental; no acredita identidad certificada ni resistencia a fotos o videos. Las plantillas permanecen cifradas en el dispositivo. No se incluyen datos biométricos de personas en este repositorio.

Consultar [instrucciones](Apple/LEEME-PRIMERO.txt) y [validación](Apple/VALIDACION-IPAD.txt).

## Comprobar compilación

En Actions, ejecutar manualmente **Comprobar VideoCall iOS**. El flujo usa un Mac estándar y compila sin firma. El resultado no se puede instalar en un iPad real hasta resolver la firma de Apple.

Los componentes de terceros conservan sus licencias en los recursos de la app.
