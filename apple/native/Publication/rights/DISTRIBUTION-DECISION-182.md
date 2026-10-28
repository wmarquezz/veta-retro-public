# Condiciones de distribución · decisión de la revisión182

28-10-2026. Esta revisión no afirma que toda appGPL esté prohibida por Apple.
Sí identifica una diferencia concreta que no está resuelta para este conjunto:

| Texto | Condición relevante | Aplicación a VETA |
|---|---|---|
| GPLv3§10 | No imponer restricciones adicionales a los derechos concedidos | Código propio, bsnes-mercury/jgenesis/melonDS y otros componentes de la matriz |
| Apple EULA estándar§a | Prohíbe transferencia/redistribución; la salvedadFOSS aparece en la cláusula de copia/modificación | No se asume que la salvedad cubra la prohibición separada de redistribuir |
| Mínimos Apple para EULA propia§§1–2 | Reglas de uso y licencia no transferible | Un aviso unilateral «GPL prevalece» no acredita aceptación de Apple |

La GPL propia y las fuentes completas son requisitos ya implementados, pero
no conceden excepciones de los terceros. Delta declara AGPLv3 en su repositorio;
es una referencia de práctica, no un permiso de sus autores o de los motores
paraVETA. PPSSPP confirma disponibilidad oficial enAppStore; tampoco constituye
un permiso adicional para todos los componentes que VETA enlaza.

## Acción concreta para resolver el impedimento

Obtener una respuesta aplicable al conjunto y al contrato real que justifique
cómo se preservan los derechosGPL en el canal, o las autorizaciones adicionales
necesarias de sus titulares. Se debe resolver la redistribución de la app,
reglas de uso y cualquier protección que imponga el canal. No basta con una
aceptación general de Apple sobre emuladores ni sólo con el consentimiento de
Winston para el código que él controla.

Esto puede sustentarse con un análisis jurídico específico; esta revisión no
sostiene que la ley obligue a contratar un abogado para toda appGPL. No se ha
obtenido ese sustento en el expediente actual. Retirar todos los componentes
GPL o sustituirlos cambiaría drásticamente las consolas y no se hace por inferencia.

## Consulta preparada, no enviada

«VETA Retro integra las versiones y licencias detalladas en LICENSE-MATRIX-176.md
y publica el código correspondiente íntegro y avisos. Pretendemos distribuir
la app para iOS enAppStore. ¿Qué base aplicable al conjunto y a los términos
actuales permite cumplir GPLv3§10 frente a las restricciones de transferencia/
redistribución del StandardEULA§a y los mínimos1–2 de una CustomEULA? Precisar
el alcance de la salvedadFOSS y, si hacen falta permisos adicionales, los derechos
que deben cubrir y de qué titulares deben obtenerse. No presumir una excepción
por la existencia de Delta u otras apps.»

No se enviaron mensajes ni aceptaron contratos. No se cambia la licencia de
terceros, no se presenta una autorización inexistente y no se retiran consolas.
El resultado de revisión es concreto: preparación técnica terminada; evidencia
de compatibilidad del canal no acreditada. No se requieren más pruebas de juegos.

Fuentes consultadas28-10-2026:
- https://www.apple.com/legal/internet-services/itunes/dev/stdeula/
- https://www.apple.com/legal/internet-services/itunes/dev/minterms/
- GPL íntegra en apple/native/COPYING, https://www.gnu.org/licenses/gpl-3.0.html
- https://github.com/rileytestut/Delta#licensing
- https://www.ppsspp.org/docs/reference/ios-support/
