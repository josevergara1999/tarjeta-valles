# Tarjeta Valles

Membresía de beneficios para zonas turísticas. El usuario compra **giros**; cada día abre una
ruleta con los beneficios disponibles de la red de comercios y elige uno. Primer lanzamiento:
Valle Las Trancas, Región de Ñuble.

> **Esto es una prueba.** El repositorio es público para que el equipo pueda revisarlo. Nada de
> lo que hay acá está aprobado todavía ni tiene datos reales: los comercios de `docs/seed-data.md`
> son inventados.

## Estado

Hito 1 — Núcleo de canje, en curso. Terminadas T0 (andamiaje), T1 (migración 001: `settings`,
`users`, `merchants`, `merchant_users`) y T2 (migración 002: `benefits`, `benefit_rules` y los 8
comercios de prueba). Las dos migraciones traen RLS y sus pruebas negativas. Siguiente: T3, los
giros y los canjes.

## Documentación

Léela en este orden:

1. `docs/spec-app-tarjeta.md` — qué hace el sistema: modelo de datos, lógica y pantallas
2. `docs/contexto-producto.md` — por qué está diseñado así. Cada regla resolvió un problema concreto
3. `docs/decisiones-hito-1.md` — decisiones firmes. Si contradice al spec, manda este documento
4. `docs/seed-data.md` — datos de prueba y escenarios que hay que poder pasar

## Puesta en marcha

```bash
npm install
cp .env.example .env.local   # y rellenar las dos variables
npm run dev
```

Las dos variables de `.env.local` son públicas —viajan al navegador— y lo que protege los datos es
Row Level Security, activo en todas las tablas. Las claves secretas no viven en el repositorio.

```bash
npm run build     # build de producción
npm run preview   # previsualizar el build
```

## Base de datos

El esquema está versionado en `supabase/migrations/` y se aplica con el CLI:

```bash
supabase db push --linked          # aplicar migraciones pendientes
supabase db advisors --linked      # revisar avisos de seguridad y rendimiento
```

Cada migración trae su script de pruebas en `supabase/tests/`. Crean sus propios datos, comprueban
lo que **no** se debe poder leer ni escribir, y terminan en `rollback`, así que no ensucian la base
y se pueden repetir:

```bash
supabase db query --linked -f supabase/tests/001_rls.sql
supabase db query --linked -f supabase/tests/002_rls.sql
supabase db query --linked -f supabase/tests/004_updated_at.sql
```

Si no imprime ningún error, el aislamiento se cumple. Que un comercio no vea los datos de otro se
prueba, no se asume.

## Estructura

```
/src
  /app-user        PWA del usuario
  /app-merchant    panel del comercio
  /app-admin       panel de administración
  /lib             lógica compartida y cliente Supabase
  /components      interfaz compartida
/supabase
  /migrations      esquema versionado
  /functions       Edge Functions
/docs
```

Las reglas de negocio —cupos, cooldown, horarios— viven en el backend, en un solo lugar. El cliente
solo muestra lo que el backend le dice.
