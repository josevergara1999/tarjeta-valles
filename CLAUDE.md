# CLAUDE.md

Archivo de contexto permanente del proyecto. Léelo al inicio de cada sesión.

## Qué es este proyecto

**Tarjeta Fidelización Global** — membresía de beneficios para zonas turísticas. El usuario compra "giros"; cada día abre una ruleta con los beneficios disponibles de la red de comercios y elige uno. Primer lanzamiento: Valle Las Trancas, Región de Ñuble, Chile.

Documentos de referencia en el repo:
- `docs/decisiones-hito-1.md` — **decisiones firmes. Si algo acá contradice el spec, manda este documento.**
- `docs/spec-app-tarjeta.md` — especificación técnica (modelo de datos, lógica, pantallas)
- `docs/contexto-producto.md` — **el porqué de cada decisión de producto. Léelo antes de proponer cambios de lógica.**
- `docs/seed-data.md` — datos de prueba

## Stack

- Frontend: React + Vite + Tailwind. PWA instalable.
- Backend/DB: Supabase (Postgres, Auth, RLS, Storage, Edge Functions)
- Auth usuario: teléfono + OTP. Auth comercio/admin: email + password.
- Pagos: (por definir — Mercado Pago o Flow)
- Hosting: Render o Vercel
- Idioma de la interfaz: **español de Chile**. Código y nombres de variables en inglés.

## Comandos

```bash
npm run dev        # desarrollo local
npm run build      # build de producción
npm run preview    # previsualizar build
```

## Reglas duras — no negociables

1. **RLS en todas las tablas desde el primer día.** Un comercio no puede leer datos de otro comercio ni de usuarios que no canjearon con él. Un usuario solo lee lo suyo. Antes de crear cualquier tabla, definir sus políticas.
   · **RLS no es lo único que hay que mirar: están también los permisos.** En Postgres una función nace con `EXECUTE` para `PUBLIC`, así que se publica sola salvo que se la revoque. Después de crear una función, **comprobar con `has_function_privilege`** en vez de confiar en el `revoke` que uno cree haber escrito. En el ACL, una entrada que empieza con `=X/` es PUBLIC, y revocarle a `anon` no la toca. Esto ya falló dos veces (migraciones 014 y 015).
   · **Las expresiones de las políticas RLS se evalúan con los privilegios de QUIEN CONSULTA**, no del dueño de la tabla. Por eso las funciones de `app` que aparecen dentro de una política tienen que seguir siendo ejecutables por `anon`/`authenticated`; cerrarlas deja la app sin poder leer nada. La lista de las que están abiertas, y por qué, vive en la migración 016. Cualquier función nueva de `app` nace cerrada (`alter default privileges`, migración 015): si una política la va a usar, hay que concederla explícitamente.
2. **Nunca commitear `.env`, claves de Supabase, ni credenciales de pago.** Verificar `.gitignore` antes del primer commit. El repo es **público**: la `anon key` puede vivir en el cliente porque la protege RLS, pero la `service_role key`, las credenciales de Twilio, las de pago y cualquier `hmac_secret` jamás salen del backend ni del gestor de secretos del hosting.
3. **El giro se descuenta cuando el comercio valida, nunca cuando el usuario elige.** Al elegir se *reserva*. Si expira sin validar, se libera. Esta regla es antifraude y no se cambia.
4. **Todo beneficio se muestra siempre junto a su condición de consumo.** Nunca mostrar "Schop de cortesía" sin "con la segunda ronda".
5. **El panel del comercio debe funcionar sin conexión** (cola local + sincronización). La señal en el valle es irregular y un canje fallido frente al cliente es un desastre operativo.
6. **No inventar reglas de negocio.** Si algo no está en el spec ni en el contexto de producto, preguntar antes de implementar.

## Convenciones de código

- Componentes en `PascalCase`, archivos de componente igual al componente.
- Nada de lógica de negocio en componentes: va en `src/lib/` o en funciones de Supabase.
- Las reglas de disponibilidad de casillas (cupos, cooldown, horarios) viven **en un solo lugar** del backend. Nunca duplicadas en el cliente — el cliente solo muestra lo que el backend le dice.
- Parámetros del negocio (cooldown, umbrales de nivel, TTL del código, comisión) en tabla `settings`, nunca hardcodeados.
- Migraciones de base de datos versionadas en `supabase/migrations/`.

## Estructura de carpetas

```
/src
  /app-user        # PWA del usuario
  /app-merchant    # panel del comercio
  /app-admin       # panel de administración
  /lib             # lógica compartida, cliente Supabase, reglas
  /components      # UI compartida
/supabase
  /migrations
  /functions
/docs
```

## Estado actual

- [ ] Hito 1 — Núcleo de canje **(en curso)** — 14 tareas, T0 a T13

  _El Security Advisor de Supabase (panel → Advisors) está en **0 errores**. Las 5 advertencias que
  quedan son conocidas y ninguna es un defecto:_
  - _4 × "Signed-In Users Can Execute SECURITY DEFINER Function" sobre `create_redemption`,
    `cancel_redemption`, `get_turn_state` y `get_available_benefits`. **Es el diseño**: son la única
    puerta de escritura del canje, tienen que ser SECURITY DEFINER para contar cupos y tomar el lock,
    y cada una comprueba `auth.uid()` adentro. No se "arregla"._
  - _1 × "Leaked Password Protection Disabled" en Auth. **Sí conviene activarla** antes de T10: los
    comercios entran con email y contraseña. Es un interruptor del panel, no código — decisión de José._
  - _1 informativa: `merchant_secrets` con RLS y sin políticas. Es el estado deseado: sin políticas
    nadie lee, y encima no tiene concesiones a ningún rol._

  _Conviene volver a pasar el Advisor después de cada tarea que agregue funciones. Encontró en un
  intento (`app.redemption_ocupa` sin `search_path`) algo que mi propia auditoría no vio, porque yo
  había filtrado por SECURITY DEFINER y esa función no lo es. **La comprobación propia hereda los
  puntos ciegos de quien la escribe.**_

  _Base_ — **las 189 comprobaciones de `supabase/tests/` pasan contra la base real (31-ago-2026).**
  Se corren pegando el archivo en el SQL Editor: cada uno abre transacción y termina en `rollback`,
  así que no dejan nada. El editor no muestra `raise notice`, solo los `raise exception`: si dice
  `Success. No rows returned`, pasaron todas.
  - [x] T0 — Andamiaje: repo, Vite + React + Tailwind, PWA, estructura, cliente Supabase
        Publicado en https://github.com/josevergara1999/tarjeta-valles (público, rama `main`).
        **La PWA ya es instalable (30-ago-2026).** El manifiesto lleva 192, 512 y `maskable`, más
        `apple-touch-icon` en el `index.html` porque iOS ignora el manifiesto. Verificado en el
        navegador sobre el build: los siete archivos responden 200 y sus dimensiones reales coinciden
        con las declaradas.
        · Los iconos los genera **`npm run iconos`** a partir de un único archivo, `public/favicon.svg`.
          Configuración en `pwa-assets.config.js`. Para cambiar el icono se sobrescribe ese SVG y se
          corre el comando: **no hay que tocar `vite.config.js` ni `index.html`**.
        · El maskable rellena todo el lienzo con `#0b0b0b`. Si se deja el relleno transparente que
          trae el preset por defecto, Android recorta el icono a círculo y se ve un cuadrado oscuro
          flotando dentro de un aro claro.
        · _El dibujo actual es un **marcador de posición** —un monograma sobre el fondo que ya estaba
          decidido en el manifiesto— acordado con José como excepción para no dejar el bloqueo para
          más adelante. **Es la excepción, no la regla:** todo lo demás que sea diseño se avisa y lo
          hace José en Claude Design._
  - [x] T1 — Migración 001: `settings`, `users`, `merchants`, `merchant_users` + RLS.
        `users.id` referencia `auth.users`; `merchant_users.auth_user_id` también; `merchants` con
        `cooldown_dias` y `hmac_secret`. Seed de los parámetros de `seed-data.md`.
        _El `hmac_secret` quedó en tabla propia (`merchant_secrets`), no como columna de `merchants`:
        RLS filtra filas, no columnas. Pruebas en `supabase/tests/001_rls.sql`._
  - [x] T2 — Migración 002: `benefits`, `benefit_rules` + RLS + seed de los 8 comercios.
        Índice único parcial: un solo beneficio activo por comercio. Horarios con `hora_fin < hora_inicio`
        y ventana nula = todo el día. Pruebas en `supabase/tests/002_rls.sql`.
        _Decisiones tomadas al implementar:_
        · `condicion_consumo` es **obligatoria** (`NOT NULL`, sin cadena vacía). La 002 la dejó nullable
          siguiendo a `seed-data.md`; la **migración 003** lo corrigió a favor del spec y de la regla
          dura 4. Un beneficio que no impone nada declara `Sin condiciones`.
        · `dias_semana` usa 0=domingo … 6=sábado, la convención de `extract(dow)`. T4 depende de esto.
        · Un trigger crea la fila de `benefit_rules` con cada beneficio, para que el 1:1 sea real y T4
          no tenga que inventar valores por defecto. Mismo patrón que `merchant_secrets` en la 001.
        · Los 8 comercios semilla llevan ids fijos `5eed0000-…`; se barren con un solo `delete`
          cuando entren comercios reales.
  - [x] T3 — Migraciones 005 a 007: `entitlements`, `redemptions` + RLS. Índice único parcial en
        `codigo` mientras `estado='pendiente'`, `motivo_anulacion`, `anulado_por`, un solo entitlement
        `bienvenida` por usuario. Los 5 usuarios semilla cargados. Pruebas en `supabase/tests/005_rls.sql`.
        _Decisiones tomadas al implementar:_
        · **Ninguna escritura del flujo de canje se abre por la API.** Crear, cancelar y validar serán
          funciones SECURITY DEFINER (T5, T6): la reserva necesita transacción con lock y eso no cabe
          en un `WITH CHECK`. Por RLS solo escribe el admin (T12, anulaciones).
        · Dos foráneas compuestas cierran incoherencias que el código podría cometer: el beneficio
          canjeado **tiene** que ser del comercio del canje (escenario 9), y el giro gastado **tiene**
          que ser del usuario que canjea. La base lo impide, no la confianza en T5.
        · `redemptions_un_pendiente_por_usuario` es más estricto que la decisión 2: un pendiente ya
          vencido pero sin marcar también bloquea. **T5 debe barrer los vencidos antes de insertar.**
        · Sin `order_id` ni `giftcard_id` en `entitlements`: esas tablas son de hitos posteriores y una
          columna uuid sin foránea es una referencia rota esperando turno.
        · ~~Pendiente de producto: cuántos giros trae cada pase.~~ **Resuelto el 30-ago-2026: días × 3.**
          Pase del Día 3, pase 3 días 9, pase 7 días 21, pase 14 días 42. Las suscripciones no se
          multiplican: 8 y 10 al mes siguen igual, la franja solo les pone techo de ritmo. Los
          `giros_totales` de la semilla (pase_7 = 8, pase_3 = 4) quedaron **desfasados** y hay que
          corregirlos. Lo que sigue abierto es el **precio**, no la cantidad — ver decisión 11.
        · Los usuarios semilla se escriben directo en `auth.users`: **no pueden iniciar sesión**, no
          tienen credencial. Sirven para probar T4-T6. Los de verdad los crea el OTP en T7.
        · **La semilla envejece y hubo que repararla (migración 011).** Sus fechas se escribieron como
          `now() - interval '2 days'` evaluado al aplicar la 005, así que los canjes recientes del
          turista salen solos de la ventana de cooldown y el escenario 4 desaparece sin que nadie
          toque nada. `app.refrescar_semilla_demo()` la devuelve a su forma desplazando todas las
          fechas por un mismo intervalo; `005_rls.sql` la llama dentro de su transacción para no
          depender del calendario. Lo detectó la primera corrida de esas pruebas, dos días después
          de sembrar.

  _El corazón, en el backend_
  - [x] T4 — Migraciones 008 a 010: franjas del día + `get_available_benefits`. Las 5 condiciones,
        única fuente de verdad. `America/Santiago`, ventanas que cruzan medianoche, cupos día y
        semana (lun-dom) contando validados + pendientes vigentes, cooldown por comercio desde
        `validado_at`. **Aplicadas y verificadas el 30-ago-2026**: las 38 comprobaciones de
        `supabase/tests/008_franjas.sql` pasan contra la base real.
        _Decisiones tomadas al implementar:_
        · La **008** parte el día en tres franjas (`franja_dia`: manana/tarde/noche) con las horas de
          corte en `settings`, encadenadas por su hora de inicio para que no queden huecos ni solapes.
          El día operativo arranca a las 06:00: un canje a la 01:00 cuenta para el día anterior, igual
          que las ventanas de los comercios. `redemptions` guarda `franja` y `dia_operativo` en vez de
          recalcularlos, para que mover una franja no reescriba el pasado.
        · `modo_ritmo_giros` en `settings` decide entre `franjas` (activo) y `libre`. Es una sola
          bifurcación dentro de `get_available_benefits`, no dos lógicas: cambiar de modo es un
          `update`, sin migración ni despliegue.
        · La **010** corrigió los giros de la semilla a días × 3 (pase_7 = 21, pase_3 = 9).
        · Las pruebas encontraron un error propio: simulaban un pendiente vencido moviendo solo
          `expira_at` al pasado, y eso choca con `redemptions_expira_despues_de_crearse` de la 005.
          Hay que retroceder también `created_at`. La restricción estaba bien; la prueba, mal.
  - [x] T5 — Migraciones 012 y 013: `create_redemption` y `cancel_redemption`. Revalida con lock,
        rechaza si el usuario ya tiene un pendiente, código de 6 dígitos + payload firmado con HMAC,
        TTL desde `settings`. Cancelar libera el giro al instante.
        **Aplicadas y verificadas el 30-ago-2026**: 25 comprobaciones en `supabase/tests/013_canje.sql`.
        _Decisiones tomadas al implementar:_
        · **Las 5 condiciones no se reescriben.** `create_redemption` le pregunta a
          `get_available_benefits()` si el beneficio sigue en la lista, ya con el lock tomado. Cuesta
          volver a correr la consulta entera para mirar una fila, y se paga con gusto: el día que
          cambie cómo se cuentan los cupos, esta función no se entera y sigue siendo correcta. Por eso
          el rechazo es un genérico `beneficio_no_disponible` y no distingue cupo de horario de
          cooldown: desglosarlo obligaría a reimplementar los tres predicados acá.
        · **Errores con `errcode = 'P0001'` y el motivo legible por máquina en DETAIL.** Un SQLSTATE
          inventado se vería mejor, pero PostgREST manda 500 ante un código que no conoce, y un "sin
          giros" no es un error del servidor. La pantalla decide con `details`, nunca parseando el
          mensaje.
        · **El formato del QR quedó fijado**: `v1.<redemption>.<merchant>.<epoch>.<hmac_sha256_hex>`,
          firmando los cuatro primeros campos. Con versión al frente para poder cambiarlo sin romper
          los paneles viejos. T10 lo va a parsear sin conexión.
        · El código de 6 dígitos sale de `gen_random_bytes`, no de `random()`: un PRNG sembrado se
          puede predecir observando unos pocos códigos, y adivinarlo permitiría quemarle el canje a
          otro.
        · La **012 va sola** porque Postgres no deja usar un valor de enum recién agregado en la misma
          transacción que lo agregó, y el CLI envuelve cada migración en una.
        · La 013 usa `create or replace` en las cuatro funciones, así que es reejecutable.
        · **La 018 cambió el contrato de T4 y obligó a tocar esta función.** `create_redemption`
          revalidaba preguntando `exists (... from get_available_benefits() where benefit_id = ...)`;
          como ahora esa lista incluye las casillas apagadas, sin un `and g.disponible` habría dejado
          reservar sobre un cupo agotado. Es el precio de delegar la regla en otra función: cuando la
          otra cambia lo que significa "estar en la lista", esta se rompe en silencio. Sigue valiendo
          la pena —una sola fuente de verdad— pero **hay que revisar a los consumidores cada vez que
          el contrato de T4 se mueva**.
        · **La 014 cerró permisos que la 013 dejó abiertos.** En Postgres una función nace con EXECUTE
          para `PUBLIC`, así que revocar solo en las dos de `public` dejó `app.firmar_canje` —que es
          SECURITY DEFINER y lee `merchant_secrets`— ejecutable por `anon` y `authenticated`. Quien
          pudiera llamarla se fabricaba un QR firmado para cualquier comercio. No era alcanzable
          porque PostgREST solo publica `public`, pero eso es una casualidad de configuración, no una
          defensa. **Regla que queda: después de crear una función, comprobar `has_function_privilege`,
          no confiar en el `revoke` que uno cree haber escrito.** Ojo con el ACL: una entrada que
          empieza con `=X/` es PUBLIC, y revocar a `anon` no la toca.
  - [x] T6 — Migración 019: `validate_redemption`. Código existente, no expirado, no usado y del
        comercio autenticado. Marca validado, **gasta el giro** e **inicia el pase**.
        **Aplicada y verificada el 31-ago-2026**: `supabase/tests/019_validacion.sql` cubre el
        escenario 1 de punta a punta (reservar → validar) y los 8 y 9 completos.
        _Decisiones tomadas al implementar:_
        · **La duración de cada pase no existía en el código.** El spec pedía `fecha_activacion + N
          días` pero el N vivía solo en el nombre del producto. Ahora está en `settings`, con la clave
          `dias_` || tipo. Si falta el parámetro la función **se cae** en vez de activar un pase sin
          vencimiento: un pase eterno no lo nota nadie hasta ver la factura de los comercios.
        · `validado_por` guarda el `merchant_users.id`, no el `auth.users.id`: interesa qué cuenta del
          local validó, que es lo que permite el reporte por operador.
        · `otro_comercio` se distingue de `canje_inexistente` a propósito. Confirma que el código
          existe, sí, pero quien pregunta es un comercio con sesión iniciada y la diferencia le sirve
          al cajero: "no es de acá" manda al cliente al local correcto. El mensaje no dice a cuál.
        · **Un `raise` deshace todo lo que la función hizo antes.** La primera versión marcaba el canje
          vencido como `expirado` y después rechazaba: código muerto, el update se iba con la
          excepción. No hace falta — un pendiente vencido no ocupa cupo por fecha, y el barrido de T5
          lo etiqueta en la próxima reserva.

  _App del usuario_ (de T7 en adelante hay pantalla: avisar y detenerse hasta que José entregue diseño)
  - [ ] T7 — Registro por teléfono: OTP internacional, fallback email, rate limit, giro de bienvenida único.
  - [ ] T8 — **Ruleta.** Consume solo lo que devuelve T4. Beneficio y condición de consumo siempre juntos.
        **El backend ya entrega todo lo que la ruleta necesita (migración 018, 31-ago-2026).**
        `get_available_benefits()` devuelve **la red entera**, disponible y apagada, con tres columnas
        nuevas: `disponible`, `motivo` y `disponible_at`. Así se pueden dibujar los escenarios 3, 4 y 5
        de `seed-data.md` —"Agotado por hoy", "Vuelve en 2 días", fuera de horario— que antes eran
        imposibles porque esos comercios ni siquiera llegaban a la pantalla.
        · `motivo` es la CAUSA (`cooldown`, `cupo_dia_agotado`, `cupo_semana_agotado`, `fuera_de_dia`,
          `fuera_de_horario`), no el texto: la redacción la pone el diseño. `disponible_at` dice cuándo
          vuelve, para que la pantalla escriba "2 días" **sin restar fechas por su cuenta**.
        · Cuando hay varios bloqueos gana **el que libera último**. Si un local está cerrado ahora y
          además en cooldown, decir "abre a las 19:00" sería mentir.
        · **`disponible` habla solo del comercio.** Que el usuario pueda girar lo sigue diciendo
          `get_turn_state()`. La pantalla combina las dos: casilla tocable = turno disponible Y casilla
          disponible. Eso hizo posible el escenario 6 — antes, un usuario sin giros recibía una lista
          vacía y no se podía ni dibujar la ruleta.
        · Un comercio o beneficio **inactivo no se devuelve**: apagado ≠ ausente. Un local que se dio
          de baja no es parte de la red, no es una casilla gris.
  - [ ] T9 — Canje activo: código grande, QR firmado, cuenta regresiva, botón de cancelar.

  _Panel del comercio_
  - [ ] T10 — Login + validar canje (pantalla de entrada por defecto, teclado grande y escáner QR).
  - [ ] T11 — Mi beneficio + Hoy: editar beneficio, cupos y horarios; canjes del día y cupos restantes.

  _Admin y cierre_
  - [ ] T12 — Admin mínimo: alta de comercios, carga manual de giros, anulación con motivo obligatorio.
  - [ ] T13 — Pasada de seguridad: escenarios 1 al 9 de `seed-data.md` + revisión de RLS tabla por tabla
        con dos cuentas de comercio. **Es la tarea que autoriza mostrar esto a alguien.**

  Toda la regla de negocio vive en T4-T6. Si aparece un cálculo de cupos o cooldown en React, es un error.
- [ ] Hito 2 — Pagos y productos
- [ ] Hito 3 — Progreso y tarjetas físicas
- [ ] Hito 4 — Reportes y giftcards
- [ ] Hito 5 — Pulido

_(Actualizar esta sección al cerrar cada hito.)_

## Cómo trabajar en este proyecto

- Antes de escribir código en una fase nueva: proponer el plan y esperar aprobación.
- **El diseño no lo hace Claude Code.** Cuando una tarea llegue a la interfaz de una sección, avisar y detenerse. José hace el diseño en Claude Design y lo entrega; recién ahí se implementa. No inventar diseño propio ni "algo provisorio" para avanzar.
- **Todo lo entregado es fase de prueba** y se publica en un repo **público** de GitHub para revisión del equipo. Si el equipo aprueba, se sigue; si no, se rehace. Repo público significa: cero credenciales en el código, siempre — ver reglas duras.
- Trabajar de a un hito. No adelantar funcionalidad de hitos posteriores aunque parezca fácil.
- Al terminar una tarea, actualizar el estado en este archivo.
