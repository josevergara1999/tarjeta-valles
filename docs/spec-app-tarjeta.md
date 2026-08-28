# Tarjeta Fidelización Global — Especificación técnica

Documento de referencia para el desarrollo. Contexto de producto: ver `plan-proyecto-tarjeta.docx`.

---

## 0. Resumen del sistema

Son **tres superficies** sobre una misma base de datos:

| Superficie | Quién la usa | Para qué |
|---|---|---|
| **App del usuario** (PWA móvil) | Turistas y residentes | Comprar giros, girar la ruleta, canjear, ver progreso |
| **Panel del comercio** (web, móvil-first) | Dueño / cajero / mesero | Validar canjes, configurar beneficio y cupos, ver reporte, activar giftcards |
| **Panel admin** (web escritorio) | José / equipo | Alta de comercios, parámetros globales, liquidaciones, stock de tarjetas, métricas |

**Regla de oro del diseño:** el giro se descuenta cuando **el comercio valida**, nunca cuando el usuario elige. Si no se valida, el giro se libera.

---

## 1. Stack recomendado

Aprovechar lo que ya está en uso (App-Equipo-Inmersia):

- **Frontend:** React (Vite, no CDN — este proyecto sí amerita build) + Tailwind
- **Backend/DB:** Supabase (Postgres + Auth + RLS + Storage + Edge Functions)
- **Auth usuario:** teléfono + OTP SMS (registro liviano, sin contraseña)
- **Auth comercio/admin:** email + password, roles vía RLS
- **Pagos:** Mercado Pago o Flow (Chile). Webpay si se requiere débito. Empezar con uno solo.
- **Hosting:** Render (ya en uso) o Vercel
- **PWA instalable**, no app nativa: sin app stores, actualización instantánea, funciona en iOS y Android.

**Crítico:** Row Level Security bien configurado desde el día uno. Un comercio jamás debe poder leer datos de otro comercio ni de usuarios que no canjearon con él. (Recordar el bug de fuga de datos entre empresas en App-Equipo-Inmersia — mismo riesgo aquí, con más consecuencias.)

---

## 2. Modelo de datos

### Tablas núcleo

```
users
  id, telefono (único), nombre, email?, created_at, ultimo_acceso

merchants
  id, nombre, rubro (enum: restaurante|cerveceria|hospedaje|minimarket|rental|gimnasio|otro),
  direccion, lat, lng, logo_url, descripcion, activo (bool), created_at

merchant_users            -- logins del local (dueño, cajero)
  id, merchant_id, email, rol (enum: dueno|operador), activo

benefits                  -- las casillas de la ruleta
  id, merchant_id, tipo (enum: cortesia|descuento),
  titulo,               -- "Schop de cortesía"
  condicion_consumo,    -- "con la segunda ronda" (obligatorio, se muestra siempre)
  descripcion?, activo (bool), created_at

benefit_rules             -- 1:1 con benefits
  benefit_id,
  cupos_dia (int|null=sin tope), cupos_semana (int|null),
  dias_semana (array 0-6), hora_inicio, hora_fin,
  cooldown_dias (default 3)
```

### Giros y consumo

```
entitlements              -- "billetera de giros" del usuario
  id, user_id,
  tipo (enum: bienvenida|pase_dia|pase_3|pase_7|pase_14|suscripcion_mensual|suscripcion_anual),
  giros_totales, giros_usados,
  estado (enum: pendiente_activacion|activo|expirado|cancelado),
  fecha_compra, fecha_activacion, fecha_expiracion,
  order_id?, giftcard_id?

orders                    -- pagos
  id, user_id, tipo_producto, monto, medio_pago,
  estado (enum: pendiente|pagado|fallido|reembolsado),
  external_payment_id, created_at

redemptions               -- canjes (la tabla más importante)
  id, user_id, entitlement_id, benefit_id, merchant_id,
  codigo (6 dígitos, único mientras vigente),
  estado (enum: pendiente|validado|expirado|anulado),
  created_at, expira_at (created_at + 5 min), validado_at, validado_por (merchant_user_id)

ratings                   -- alimenta el ranking
  id, redemption_id, user_id, merchant_id, estrellas (1-5), comentario?, created_at
```

### Tarjetas físicas

```
physical_cards
  id, nivel (1|2|premium), edicion, numero_serie,
  estado (enum: stock|reservada|entregada),
  merchant_id (dónde está el stock), user_id?, entregada_at, entregada_por

card_unlocks              -- desbloqueos del usuario
  id, user_id, nivel, canjes_al_desbloquear, estado (enum: desbloqueada|retirada),
  desbloqueada_at, retirada_at, physical_card_id?
```

### Giftcards

```
giftcards
  id, codigo (único, oculto hasta venta), tipo (pase_3|membresia_1m|membresia_3m),
  canal (enum: local|online),
  estado (enum: inactiva|vendida|canjeada|expirada),
  merchant_id? (quién la vendió), vendida_at, vendida_por,
  canjeada_at, canjeada_por_user_id,
  monto, comision_merchant, settlement_id?

settlements               -- liquidaciones mensuales por comercio
  id, merchant_id, periodo (YYYY-MM), total_vendido, comision, monto_a_transferir,
  estado (enum: pendiente|pagado), pagado_at
```

### Parámetros globales (tabla `settings` o config)

`cooldown_dias_default=3`, `ttl_codigo_canje_minutos=5`, `canjes_nivel_1=10`, `canjes_nivel_2=35`, `canjes_premium=100`, `giros_extra_nivel_1=2`, `giros_extra_nivel_2=4`, `giros_extra_premium=6`, `comision_giftcard=0.10`

---

## 3. Lógica de negocio crítica

### 3.1 Qué casillas ve el usuario hoy (el corazón del sistema)

Un beneficio aparece en la ruleta de un usuario **solo si se cumplen todas**:

1. `merchant.activo` y `benefit.activo`
2. Estamos dentro de `dias_semana` + `hora_inicio`/`hora_fin`
3. Cupos disponibles: `redemptions validados hoy < cupos_dia` (y lo mismo para la semana)
4. Cooldown: el usuario no canjeó en ese `merchant_id` en los últimos `cooldown_dias`
5. El usuario tiene al menos 1 giro disponible en algún `entitlement` activo

Si falla (3) → mostrar la casilla **apagada** con "Agotado por hoy".
Si falla (4) → mostrar apagada con **contador**: "Vuelve en 2 días". (No ocultarlas: la restricción visible genera anticipación.)

**Orden de las casillas:** ranking por satisfacción — promedio de `ratings.estrellas` (ponderado por volumen) + tasa de retorno (usuarios que canjearon 2+ veces en ese local). **Nunca** por tamaño del beneficio. Los espacios pagados (fase 2) van marcados y separados, arriba de la lista orgánica.

### 3.2 Flujo de canje (anti-fraude)

```
1. Usuario elige casilla en la ruleta
2. Backend valida disponibilidad (las 5 condiciones), crea redemption
   estado=pendiente, código 6 dígitos, expira_at = now + 5 min
   → el giro queda RESERVADO, no descontado
3. App muestra código grande + QR + cuenta regresiva
4. El comercio, desde su panel, ingresa el código (o escanea el QR)
5. Backend valida: código existe, no expirado, pertenece a ese merchant
   → estado=validado, giros_usados += 1, progreso += 1
6. Ambas pantallas confirman. Se pide rating al usuario (opcional, 1 toque)
7. Si expira sin validar → estado=expirado, giro liberado
```

**Por qué así:** el usuario no puede hacer screenshot y reutilizar; el comercio no puede validar canjes falsos porque el código lo genera el sistema; y si el usuario se arrepiente, no perdió el giro.

**Modo contingencia (sin internet en el local):** el panel guarda el código en cola local y lo sincroniza al recuperar señal. Necesario — la señal en el valle es irregular.

### 3.3 Activación de pases

- Un pase comprado queda `pendiente_activacion`.
- Se activa con el **primer canje** o con un botón "activar ahora".
- Desde ahí corren los días: `fecha_expiracion = fecha_activacion + N días`.
- Los giros no usados se pierden al expirar (no se devuelven ni transfieren).

### 3.4 Suscripción

- Paquete mensual de giros: 8 (mensual) / 10 (anual) + extras por nivel de tarjeta.
- **Los giros se resetean cada ciclo, no se acumulan.**
- Cobro recurrente: si el proveedor de pago no soporta suscripción, implementar como renovación manual con recordatorio (aceptable para el MVP).

### 3.5 Progreso y tarjetas físicas

- El progreso = `count(redemptions.estado='validado')` histórico del usuario.
- Al cruzar el umbral → se crea `card_unlocks` estado=desbloqueada, notificación en app.
- La app muestra los locales con `physical_cards` en estado `stock` de ese nivel.
- El local valida el desbloqueo en su panel → asigna una `physical_card`, estado=entregada.
- Los giros extra del nivel se aplican al siguiente ciclo de suscripción.

### 3.6 Giftcards

- Se generan en lote desde el admin, estado `inactiva`, se imprimen con código oculto.
- El comercio la **activa al venderla** desde su panel (escaneando o ingresando el código) → estado=vendida, se registra `merchant_id` y comisión.
- El receptor ingresa el código en la app → se crea el `entitlement` correspondiente.
- Regla: en el canal `local` solo existe `tipo=pase_3`. Membresías solo `canal=online`.

---

## 4. Pantallas

### App del usuario (PWA)

1. **Onboarding / QR** — landing al escanear el QR de un local: qué es, beneficio de bienvenida, registro (teléfono + OTP)
2. **Ruleta** (pantalla principal) — casillas disponibles, apagadas con motivo, giros restantes visibles
3. **Canje activo** — código + QR + cuenta regresiva
4. **Mi progreso** — barra hacia la próxima tarjeta, historial de canjes, nivel actual
5. **Comprar giros** — pases y suscripción, con el comparativo que empuja al escalón siguiente
6. **Mapa / listado de locales** — ficha de cada comercio, su beneficio, ubicación
7. **Mi tarjeta** — estado del desbloqueo y dónde retirarla
8. **Canjear código** — para giftcards

### Panel del comercio (móvil-first: se usa en la barra)

1. **Validar canje** — pantalla de entrada por defecto: teclado numérico grande + escáner QR
2. **Mi beneficio** — editar título, condición de consumo, cupos, horarios; switch de activo/inactivo bien visible
3. **Hoy** — canjes del día, cupos restantes en tiempo real
4. **Reporte** — canjes por período, clientes generados, valoración, posición en categoría
5. **Giftcards** — activar venta, stock, comisión acumulada del mes
6. **Tarjetas físicas** — stock disponible, entregar (validar desbloqueo)

### Panel admin

1. Comercios (alta, edición, activación)
2. Beneficios y cupos (override global)
3. Usuarios y entitlements (soporte)
4. Tarjetas físicas: lotes, series, distribución de stock por local
5. Giftcards: generación de lotes, estado, liquidaciones
6. Métricas: conversión escaneo→compra, giros usados/disponibles, cupos agotados por local, ingresos
7. Parámetros globales

---

## 5. Qué NO construir en el MVP

Dejar explícitamente fuera de la primera versión:

- Rutas prearmadas, modo grupo, temporadas, casilla sorpresa
- Notificaciones push (usar WhatsApp/email al inicio)
- App nativa
- Integración con PMS de hospedajes
- Espacios destacados pagados (fase 4 del plan)
- Sistema de comentarios largos (solo estrellas)

---

## 6. Orden de construcción sugerido

**Hito 1 — Núcleo de canje.** Auth por teléfono, merchants + benefits + rules, ruleta con las 5 condiciones, flujo de canje con código, panel del comercio con validación. *Sin pagos: giros cargados a mano desde admin.* Se puede probar en terreno con 2-3 locales amigos.

**Hito 2 — Pagos y productos.** Integración de pasarela, entitlements, compra de pases y suscripción, activación, expiración.

**Hito 3 — Progreso y tarjetas físicas.** Barra de progreso, niveles, desbloqueo, stock por local, entrega presencial.

**Hito 4 — Reportes y giftcards.** Reporte del comercio, ratings, ranking por satisfacción, generación y activación de giftcards, liquidaciones.

**Hito 5 — Pulido.** Modo offline en el panel, mapa, onboarding fino, métricas admin.

Lanzar públicamente al terminar el Hito 3. Los hitos 1 y 2 pueden probarse en marcha blanca con la red fundadora.

---

## 7. Notas de diseño de interfaz

- **La ruleta es la identidad visual del producto.** Reutilizar el aprendizaje del prototipo de Valle Aventura, pero con una diferencia clave: aquí **el usuario elige la casilla, no hay azar**. La ruleta es la forma de presentar y seleccionar, no un sorteo.
- El panel del comercio se usa de pie, con una mano, en un lugar con ruido. Botones grandes, contraste alto, cero pasos innecesarios. La pantalla de validar canje debe abrirse en menos de 2 toques.
- Todo beneficio se muestra **siempre junto a su condición de consumo**. Evita el 90% de los conflictos en el mostrador.
- Los estados apagados (agotado, en cooldown) deben verse como parte del juego, no como error.
