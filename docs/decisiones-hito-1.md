# Decisiones — review previo al Hito 1

Respuestas a los huecos detectados en la revisión de la especificación. Estas decisiones son firmes; si algo acá contradice `spec-app-tarjeta.md`, manda este documento.

---

## Bloqueantes

### 1. Sobreventa de cupos — CORRECTO, hay que arreglarlo

Para reservar, el cupo se evalúa contando **canjes validados + pendientes no expirados**:

```
ocupados_hoy = count(redemptions
  where benefit_id = X
  and (estado = 'validado'
       or (estado = 'pendiente' and expira_at > now()))
  and fecha = hoy)
```

La reserva debe hacerse en una **transacción con lock** sobre el beneficio (o `SELECT ... FOR UPDATE`), no con un chequeo previo seguido de un insert: dos usuarios simultáneos pasarían ambos el chequeo. Misma lógica para `cupos_semana`.

### 2. Un canje pendiente por usuario — CONFIRMADO

**Máximo un canje pendiente a la vez por usuario.** Si intenta abrir uno nuevo teniendo otro vigente, la app le ofrece cancelar el anterior (lo que libera el giro de inmediato) o esperar a que expire. Es lo correcto operativamente: nadie está en dos locales al mismo tiempo, y simplifica todo el control de saldo.

### 3. Cooldown — es por COMERCIO, y corre desde la validación

- `cooldown_dias` **se mueve de `benefit_rules` a `merchants`** (con default global en `settings`). La regla de producto es "ese local se apaga", no "ese beneficio".
- Corre **desde `validado_at`**, nunca desde la reserva. Un canje abandonado o expirado no puede castigar al usuario.

### 4. Un beneficio activo por comercio — CONFIRMADO para el Hito 1

Tu recomendación es la correcta. El modelo soporta varios (`benefits` con `merchant_id`), pero **solo uno puede estar activo a la vez** por comercio, y la ruleta muestra **una casilla por comercio**. El ranking también se calcula por comercio.

Razón de producto: el mesón no aguanta ambigüedad, y el dueño tiene que poder responder "¿cuál es mi beneficio?" con una sola frase. Múltiples beneficios simultáneos quedan para después, si los datos lo piden.

### 5. Offline — opción (b), QR con payload firmado

Se elige **(b)**, y se define el formato del código ahora aunque el modo offline se implemente en el Hito 5.

El QR lleva: `redemption_id`, `merchant_id`, `expira_at` y un **HMAC firmado con un secreto por comercio**. El panel valida la firma y la expiración sin internet.

Con una salvedad que hay que asumir explícitamente: **el HMAC prueba autenticidad, no unicidad.** Offline no se puede verificar que ese código no se haya usado ya en otro dispositivo del mismo local ni que el cupo siga disponible. Mitigación:

- El panel guarda en caché local los códigos ya validados en ese dispositivo (evita el doble uso obvio).
- El modo offline tiene un **tope de canjes acumulados sin sincronizar** (ej: 10). Superado, el panel exige conexión.
- Al sincronizar, un canje huérfano o duplicado se registra como incidencia en el reporte, y el criterio es **el local no pierde**: el canje se honra, el sistema lo marca.

Los 6 dígitos tecleados quedan como respaldo para el caso online (QR ilegible, cámara sucia, pantalla rota).

### 6. Zona horaria y ventanas nocturnas — CORRECTO

- Toda evaluación de horarios y de "hoy" se hace en **`America/Santiago`**. Guardar timestamps en UTC, comparar en zona local. Chile cambia hora dos veces al año y el sistema opera justo en invierno.
- El modelo debe soportar **`hora_fin < hora_inicio`** (cervecería de 21:00 a 02:00): en ese caso la ventana cruza medianoche y el canje de la 01:00 pertenece al día anterior para efectos de cupos.

### 7. Vínculo con Supabase Auth — CORRECTO

- `users.id` **es** `auth.uid()` (referencia a `auth.users`).
- `merchant_users` necesita `auth_user_id` con su propia referencia.
- Sin esto no hay RLS posible. Corregir el modelo antes de la primera migración.

### 8. Expiración — al vuelo, sin cron — CONFIRMADO

Un canje se considera expirado comparando `expira_at` en cada consulta. Nunca depender de un job para una regla de negocio. El cron opcional solo marca registros viejos por prolijidad de datos.

### 9. Identidad y OTP

- **Se aceptan números internacionales** desde el MVP. Los visitantes argentinos son un segmento real en Nevados de Chillán y excluirlos por defecto sería cerrar la puerta al cliente de mayor ticket.
- **Rate limit obligatorio**: máximo 3 envíos de OTP por número por hora y 5 por IP por hora. Sin esto, la cuenta de Twilio queda abierta.
- **Fallback por email OTP** (nativo en Supabase, sin costo): si el SMS no llega, el usuario puede registrarse por correo. Evita perder al usuario que está parado en el local con el mesero mirando.
- Monitorear el costo de SMS en la marcha blanca: si se dispara, se revisa.

### 10. Giro de bienvenida — uno por usuario, de por vida — CONFIRMADO

No uno por local escaneado. Se registra en el `entitlement` de tipo `bienvenida`, que solo puede existir una vez por `user_id`.

---

### 11. Tres giros por día, uno por franja — DECIDIDO 29-ago-2026

El día se divide en **tres franjas: mañana, tarde y noche**, y el usuario tiene **un giro por
franja**. La promesa del producto es una jornada planificada —arriendo de equipo en la mañana,
almuerzo, cervecería al cierre del día— y por eso la franja es una **regla que el sistema hace
cumplir**, no una sugerencia de pantalla: nadie puede quemar los tres giros en el almuerzo.

- Los límites horarios de las franjas viven en `settings`, nunca en el código ni en el cliente.
- La franja de noche **cruza medianoche**. Un canje a la 01:00 pertenece a la noche del día
  anterior, exactamente igual que las ventanas horarias de los comercios (decisión 6).
- El techo aplica **por franja, no por día**: haber gastado la mañana no impide la tarde, y no
  haber gastado la mañana no regala un giro extra a la noche. La franja perdida se pierde.
- El total de giros de un pase sale de multiplicar sus días por tres. Un pase de 3 días son
  9 giros, con un máximo de 3 por día y 1 por franja.
- Esto convive con el saldo del `entitlement`: la franja es un **techo de ritmo**, no una fuente
  de giros. Si al usuario le queda un solo giro, la franja no se lo multiplica.

**El modo libre queda disponible para probarlo.** A José le convence también la variante sin
franjas —tres giros al día y el usuario los gasta cuando quiera— así que el ritmo es un
parámetro y no una regla tallada en el código:

- `modo_ritmo_giros` en `settings`: `franjas` (el modo activo) o `libre`.
- En `libre`, el techo es `giros_por_dia` canjes por día operativo y las franjas no se evalúan.
- **No son dos lógicas duplicadas.** Es una sola bifurcación dentro de `get_available_benefits`,
  que sigue siendo la única fuente de verdad. Cambiar de modo es un `update` en `settings`, sin
  migración, sin tocar el cliente y sin desplegar.

**La cantidad de giros por pase quedó cerrada el 30-ago-2026.** José lo confirmó: *"el pase diario
tiene 1 ruleta; 1 giro significa 3 giros a lo largo del día, mañana, tarde y noche"*. Es el caso de
un día de la misma regla, así que **días × 3** vale para todos los pases:

| Pase del Día | Pase 3 días | Pase 7 días | Pase 14 días |
|---|---|---|---|
| 3 giros | 9 giros | 21 giros | 42 giros |

Las suscripciones no entran en esta multiplicación: sus 8 y 10 giros mensuales son una bolsa, y la
franja solo les pone un techo de ritmo de 3 al día.

**LO QUE SIGUE PENDIENTE ES EL PRECIO, NO LOS GIROS.** Con la tabla corregida, el Pase 7 días sale
a ~$376 por beneficio y el de 14 a ~$307, contra **$625 de la suscripción mensual**: el pase largo
deja de competir con la suscripción y la deja sin sentido. Solo la anual ($300) queda por debajo, y
apenas.

Puede ser correcto que el pase turístico sea generoso —el turista está pocos días y quiere
exprimirlos, y la suscripción se defiende por otro lado, que es ser para residentes todo el año—
pero **es una decisión de precio y de salud de la red que hay que tomar aparte**. Los precios de
`contexto-producto.md` quedaron **sin tocar** a la espera de esa decisión. Mientras tanto, T4 solo
implementa el techo por franja, que no depende de cuántos giros traiga cada producto.

---

## Menores

| Punto | Decisión |
|---|---|
| Semana de `cupos_semana` | **Semana calendario lunes a domingo** en `America/Santiago`. Más fácil de explicar al dueño ("se te reinician los lunes") que una ventana móvil. |
| TTL de 5 min | Se lee de `settings.ttl_codigo_canje_minutos`. Ningún parámetro de negocio hardcodeado. |
| Tabla `settings` | Agregarla al modelo de datos: `key`, `value`, `tipo`, `descripcion`. Los valores iniciales están en `seed-data.md`. |
| Estado `anulado` | Anulación manual desde el panel admin (soporte: canje mal validado, reclamo del usuario). **Devuelve el giro** y no cuenta para progreso ni para cupos. Requiere `motivo` y `anulado_por`. |
| Pase 14 días = 12 giros | **Descartado el 30-ago-2026.** Son **42** (14 días × 3 franjas). El argumento original —mantener la curva de precio por giro descendente y que el pase largo no compitiera con la suscripción— se apoyaba en poner los giros por debajo de los días, y la decisión 11 lo dejó sin piso. La tabla de `contexto-producto.md` ya está corregida. Lo que queda abierto es el **precio**, no la cantidad de giros. |
| Unicidad de `redemptions.codigo` | Índice único parcial: único mientras `estado = 'pendiente'`. Los códigos históricos pueden repetirse. |
| Condición de consumo vacía | **La condición es obligatoria, siempre** (29-ago-2026). El spec ya lo pedía y la regla dura 4 también; esta tabla tenía tres beneficios con la casilla en blanco y eso era el error. Un beneficio que no impone nada lo dice: `Sin condiciones`. La columna es `NOT NULL` y rechaza la cadena vacía. |
| Ubicación de archivos | Correcto: mover `spec-app-tarjeta.md`, `contexto-producto.md` y `seed-data.md` a `/docs`. `CLAUDE.md` va en la raíz. |

---

## Cambios al modelo de datos que se desprenden

1. `merchants` gana `cooldown_dias` (nullable, default desde `settings`) y `hmac_secret`.
2. `benefit_rules` pierde `cooldown_dias`.
3. `users.id` referencia `auth.users`.
4. `merchant_users` gana `auth_user_id`.
5. Nueva tabla `settings`.
6. `redemptions` gana `motivo_anulacion` y `anulado_por`; índice único parcial en `codigo`.
7. `benefits`: constraint que impide más de un beneficio `activo = true` por `merchant_id`.
8. `benefits.condicion_consumo` es `NOT NULL` y no admite cadena en blanco.
9. `benefit_rules` es 1:1 de verdad: un trigger la crea junto con el beneficio, para que T4 no tenga
   que inventarse valores por defecto y la regla no viva en dos lugares.
10. `settings` gana los límites horarios de las tres franjas del día (decisión 11), y `redemptions`
    registra en qué franja se hizo el canje: sin ese dato, comprobar "¿ya gastó la tarde?" obliga a
    recalcular la franja a partir del reloj cada vez, y el resultado cambiaría si algún día se mueven
    los horarios.
