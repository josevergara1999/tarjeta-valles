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

- [ ] Hito 1 — Núcleo de canje **(en curso)**
  - [x] T0 — Andamiaje: repo, Vite + React + Tailwind, PWA, estructura, cliente Supabase
  - [ ] T1 — Migración 001: `settings`, `users`, `merchants`, `merchant_users` + RLS
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
