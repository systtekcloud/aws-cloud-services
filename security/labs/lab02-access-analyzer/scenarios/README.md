# Escenarios SAA-C03 — IAM Access Analyzer

---

## Escenario 1 — Bucket S3 accesible desde internet

**Situación:** Un equipo de desarrollo ha creado un bucket S3 para alojar assets estáticos de una aplicación web interna. Al revisar los findings de IAM Access Analyzer, aparece el bucket con `isPublic: true`. El equipo afirma que no era su intención hacerlo público.

**Pregunta:** ¿Qué combinación de acciones remedia el problema de forma permanente?

A) Eliminar la bucket policy del bucket
B) Habilitar Block Public Access (BPA) en el bucket
C) Eliminar la bucket policy + habilitar Block Public Access
D) Archivar el finding en Access Analyzer

**Respuesta correcta: C**

**Explicación:**
- Solo eliminar la policy (A) no es suficiente — si BPA está desactivado, alguien podría volver a añadir una policy pública en el futuro
- Solo BPA (B) bloquea las nuevas policies públicas pero no elimina la policy existente
- La combinación (C) es la remediación completa: eliminar el acceso actual + prevenir futuros accesos públicos
- Archivar el finding (D) no remedía nada — solo oculta el finding sin cambiar la configuración

---

## Escenario 2 — IAM Role para herramienta de auditoría de terceros

**Situación:** Una empresa usa una herramienta de auditoría de seguridad SaaS (cuenta AWS: `987654321098`). Para que la herramienta pueda auditar recursos, el equipo de seguridad creó un IAM Role con trust policy que permite `AssumeRole` desde esa cuenta. IAM Access Analyzer genera un finding activo para ese rol.

**Pregunta:** ¿Qué acción es la más apropiada?

A) Eliminar el IAM Role y usar otro método de acceso
B) Archivar el finding con documentación de por qué el acceso es legítimo
C) Cambiar la trust policy para que solo permita `AssumeRole` con MFA
D) Ignorar el finding — Access Analyzer no analiza IAM Roles

**Respuesta correcta: B**

**Explicación:**
- El acceso cross-account es intencionado y necesario para la herramienta de auditoría
- Archivar el finding (B) es la acción correcta para accesos externos documentados y autorizados
- Eliminar el rol (A) rompería la integración con la herramienta de auditoría
- Añadir MFA (C) puede ser una mejora de seguridad válida, pero no resuelve el finding
- Access Analyzer sí analiza IAM Roles (D es incorrecto) — es uno de los recursos principales que analiza

---

## Escenario 3 — Diferencia entre analyzer de cuenta vs organización

**Situación:** Una empresa tiene AWS Organizations con tres cuentas: Management (123456789012), Security (111111111111) y Dev (222222222222). En la cuenta Dev hay un IAM Role que permite `AssumeRole` desde la cuenta Security (para acceso centralizado de auditores). Tienen un IAM Access Analyzer de tipo `ACCOUNT` en la cuenta Dev.

**Pregunta:** ¿Qué ocurre con el finding del IAM Role?

A) No se genera ningún finding porque la cuenta Security es de confianza
B) Se genera un finding activo porque el acceso es desde fuera de la cuenta Dev
C) Se genera un finding pero se archiva automáticamente si Organizations está configurado
D) Se generan dos findings: uno por cada cuenta de la organización

**Respuesta correcta: B**

**Explicación:**
- Con un analyzer de tipo `ACCOUNT`, la zona de confianza es únicamente la cuenta Dev
- Cualquier acceso desde fuera de la cuenta Dev (incluyendo otras cuentas de la organización) genera un finding activo
- Para evitar este finding, habría que usar un analyzer de tipo `ORGANIZATION` — así la zona de confianza abarca todas las cuentas de la organización
- Los findings no se archivan automáticamente (C es incorrecto)
- Solo se genera un finding por recurso, no por cada cuenta externa (D es incorrecto)

**Regla SAA-C03:**
- `ACCOUNT` analyzer → finding para cualquier acceso externo a la cuenta
- `ORGANIZATION` analyzer → finding solo para accesos externos a la organización completa
