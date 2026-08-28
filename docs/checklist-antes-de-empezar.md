# Antes de abrir Claude Code

## 1. Decisiones que tienes que tomar tú

Claude Code no puede resolver estas. Cada una bloquea una parte del desarrollo.

| Decisión | Bloquea | Recomendación |
|---|---|---|
| **Pasarela de pago:** Mercado Pago o Flow | Hito 2 | Mercado Pago si quieres partir rápido y con checkout conocido por el usuario chileno. Flow si prefieres comisiones más bajas y ya tienes cuenta. |
| **Proyecto Supabase: ¿nuevo o el de INMERSIA?** | Hito 1 | **Nuevo y separado.** Otro producto, otros usuarios, otro riesgo. No mezclar. |
| **Repo GitHub** | Hito 1 | Nuevo, privado. |
| **Hosting** | Hito 1 | Render (ya lo conoces) o Vercel (mejor para Vite/PWA). |
| **Envío de SMS para el OTP** | Hito 1 | Supabase Auth con Twilio. Tiene costo por SMS — considerarlo en la operación. |
| **Nombre y marca** | Hito 3 | Se puede construir con diseño neutro, pero la ruleta *es* el producto: resolver antes de que la vea un usuario real. |

## 2. Lo que tiene que estar listo en el repo

```
/docs
  spec-app-tarjeta.md
  contexto-producto.md
  seed-data.md
CLAUDE.md          ← en la raíz, no en /docs
.gitignore         ← con .env incluido ANTES del primer commit
```

## 3. Prompt para la primera sesión

Copia esto tal cual:

---

Lee `CLAUDE.md`, `docs/spec-app-tarjeta.md`, `docs/contexto-producto.md` y `docs/seed-data.md` antes de responder nada.

Este proyecto se construye por hitos, uno a la vez. **No escribas código todavía.**

Lo que necesito en esta sesión:

1. Confírmame que entendiste el producto explicándome en tus palabras: qué es un "giro", por qué el giro se reserva y no se descuenta al elegir, y por qué el ranking mide satisfacción y no generosidad. Si algo no te queda claro, pregúntame.

2. Señálame las **contradicciones, huecos o riesgos técnicos** que veas en la especificación. Prefiero descubrirlos ahora.

3. Propón el **plan de ejecución del Hito 1 (Núcleo de canje)** dividido en tareas pequeñas y verificables, en orden de dependencia. Para cada tarea: qué archivos toca, qué queda funcionando al terminarla, y cómo la pruebo yo. Ninguna tarea debería tomar más de una sesión de trabajo.

4. Dime qué decisiones necesitas de mí antes de empezar a programar.

No avances al Hito 2 ni menciones funcionalidades de hitos posteriores. Cuando apruebe el plan, empezamos por la primera tarea.

---

## 4. Cómo trabajar después

- **Una tarea por sesión.** Al terminar, pídele que actualice el estado en `CLAUDE.md` y haga commit.
- **Prueba tú cada tarea antes de seguir.** Si no puedes verificarla, la tarea estaba mal definida.
- **Al cerrar un hito**, pídele el plan del siguiente igual que arriba: primero plan, luego código.
- Si propone cambiar una regla de negocio, mándalo a `contexto-producto.md`. Casi todas las reglas que parecen complicadas resolvieron un problema real.
- Cuando algo salga mal en terreno (un canje que falló, un local confundido), anótalo — eso es lo que define el Hito 5.

## 5. Recordatorios de seguridad

- `.env` en `.gitignore` **antes** del primer commit. Si se te escapa una clave, rótala.
- RLS activo en cada tabla desde su creación, no "después".
- Nunca claves de pago en el frontend: la pasarela se integra por backend.
- Antes de la marcha blanca con locales reales: revisar que un comercio no pueda ver datos de otro. Probarlo, no asumirlo.
