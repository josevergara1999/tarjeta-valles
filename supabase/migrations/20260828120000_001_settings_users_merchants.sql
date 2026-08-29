-- Migración 001 — Base: settings, users, merchants, merchant_users
-- Hito 1 · T1. Referencias: docs/decisiones-hito-1.md (manda sobre el spec), docs/spec-app-tarjeta.md.
--
-- Todo lo de acá nace con RLS activo. Ninguna tabla del proyecto se crea sin sus políticas.

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------------
-- Esquema de helpers. No lo expone PostgREST: nadie lo llama desde el cliente.
-- ---------------------------------------------------------------------------

create schema if not exists app;
comment on schema app is 'Helpers internos de RLS y de parámetros. Fuera del alcance de PostgREST.';
grant usage on schema app to authenticated;

-- ---------------------------------------------------------------------------
-- Tipos
-- ---------------------------------------------------------------------------

create type public.rubro as enum (
  'restaurante', 'cerveceria', 'hospedaje', 'minimarket', 'rental', 'gimnasio', 'otro'
);

create type public.merchant_rol as enum ('dueno', 'operador');

create type public.setting_tipo as enum ('entero', 'decimal', 'booleano', 'texto');

-- ---------------------------------------------------------------------------
-- settings — parámetros del negocio. Nada de esto se hardcodea en el código.
-- ---------------------------------------------------------------------------

create table public.settings (
  key         text primary key,
  value       text not null,
  tipo        public.setting_tipo not null,
  descripcion text not null,
  updated_at  timestamptz not null default now()
);

comment on table public.settings is
  'Parámetros globales del negocio. Se leen en tiempo de ejecución, nunca se copian al código como constante.';

-- ---------------------------------------------------------------------------
-- users — la fila de aplicación del usuario final. users.id ES auth.uid().
-- ---------------------------------------------------------------------------

create table public.users (
  id            uuid primary key references auth.users (id) on delete cascade,
  telefono      text unique,
  nombre        text,
  email         text,
  created_at    timestamptz not null default now(),
  ultimo_acceso timestamptz
);

comment on column public.users.telefono is
  'E.164 con código de país: se aceptan números internacionales desde el MVP (decisión 9). Nulo si el usuario entró por el fallback de email.';

-- ---------------------------------------------------------------------------
-- merchants — los comercios de la red.
-- ---------------------------------------------------------------------------

create table public.merchants (
  id            uuid primary key default gen_random_uuid(),
  nombre        text not null,
  rubro         public.rubro not null,
  direccion     text,
  lat           double precision,
  lng           double precision,
  logo_url      text,
  descripcion   text,
  activo        boolean not null default true,
  cooldown_dias smallint check (cooldown_dias >= 0),
  created_at    timestamptz not null default now()
);

comment on column public.merchants.cooldown_dias is
  'Días que ese local se apaga para un usuario tras validarle un canje. El cooldown es por COMERCIO, no por beneficio (decisión 3). Nulo = usar settings.cooldown_dias_default.';

create index merchants_activo_idx on public.merchants (activo) where activo;

-- El hmac_secret vive aparte, no como columna de merchants.
--
-- La decisión 5 pide un secreto por comercio para firmar el QR. RLS es por fila, no por columna: si
-- el secreto fuera una columna de merchants, cualquier `select *` autorizado a leer el comercio se
-- lo llevaría. En tabla propia, con RLS activo y sin una sola política, no lo lee nadie por la API:
-- solo el service_role y las funciones SECURITY DEFINER que firmarán el código en T5.
create table public.merchant_secrets (
  merchant_id uuid primary key references public.merchants (id) on delete cascade,
  hmac_secret text not null default encode(extensions.gen_random_bytes(32), 'hex'),
  created_at  timestamptz not null default now()
);

create function app.merchant_secret_autocreate()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.merchant_secrets (merchant_id) values (new.id);
  return new;
end;
$$;

create trigger merchants_secret_autocreate
  after insert on public.merchants
  for each row execute function app.merchant_secret_autocreate();

-- ---------------------------------------------------------------------------
-- merchant_users — los logins del local. auth_user_id es lo que hace posible el RLS.
-- ---------------------------------------------------------------------------

create table public.merchant_users (
  id           uuid primary key default gen_random_uuid(),
  merchant_id  uuid not null references public.merchants (id) on delete cascade,
  auth_user_id uuid unique references auth.users (id) on delete set null,
  email        text not null,
  rol          public.merchant_rol not null default 'operador',
  activo       boolean not null default true,
  created_at   timestamptz not null default now(),
  unique (merchant_id, email)
);

comment on column public.merchant_users.auth_user_id is
  'Nulo mientras el admin dio de alta la cuenta y el local todavía no la usó. Único: una cuenta pertenece a un solo comercio.';

create index merchant_users_merchant_idx on public.merchant_users (merchant_id);

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- SECURITY DEFINER a propósito: lee merchant_users saltándose su propio RLS. Sin esto, la política
-- de merchant_users se llamaría a sí misma.
create function app.current_merchant_id()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select mu.merchant_id
  from public.merchant_users mu
  where mu.auth_user_id = (select auth.uid())
    and mu.activo
  limit 1;
$$;

comment on function app.current_merchant_id() is
  'Comercio del usuario autenticado, o NULL si quien llama es un usuario final. Ese NULL es lo que distingue a las dos audiencias en las políticas.';

-- El admin se marca en app_metadata, que solo se escribe con la service_role key: un usuario no
-- puede ascenderse a sí mismo editando su perfil.
create function app.is_platform_admin()
returns boolean
language sql
stable
set search_path = ''
as $$
  select coalesce(((select auth.jwt()) -> 'app_metadata' ->> 'platform_admin')::boolean, false);
$$;

create function app.setting_text(p_key text)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select s.value from public.settings s where s.key = p_key;
$$;

create function app.setting_int(p_key text)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select s.value::integer from public.settings s where s.key = p_key;
$$;

create function app.setting_numeric(p_key text)
returns numeric
language sql
stable
security definer
set search_path = ''
as $$
  select s.value::numeric from public.settings s where s.key = p_key;
$$;

grant execute on function
  app.current_merchant_id(),
  app.is_platform_admin(),
  app.setting_text(text),
  app.setting_int(text),
  app.setting_numeric(text)
  to authenticated;

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------

alter table public.settings         enable row level security;
alter table public.users            enable row level security;
alter table public.merchants        enable row level security;
alter table public.merchant_secrets enable row level security;
alter table public.merchant_users   enable row level security;

-- merchant_secrets: RLS activo y ninguna política. Nadie, por la API, nunca.
revoke all on public.merchant_secrets from anon, authenticated;

-- settings: los lee cualquiera autenticado (el cliente necesita el TTL para la cuenta regresiva).
-- Escribirlos es del admin.
create policy settings_select on public.settings
  for select to authenticated
  using (true);

-- Tres políticas y no un `for all`: si el admin entrara también por SELECT se evaluarían dos
-- políticas permisivas en cada lectura, y la ruleta lee esto en cada carga.
create policy settings_insert_admin on public.settings
  for insert to authenticated
  with check (app.is_platform_admin());

create policy settings_update_admin on public.settings
  for update to authenticated
  using (app.is_platform_admin())
  with check (app.is_platform_admin());

create policy settings_delete_admin on public.settings
  for delete to authenticated
  using (app.is_platform_admin());

-- users: cada uno lo suyo.
-- (En T3, cuando exista redemptions, se agrega la política que deja al comercio ver a los usuarios
-- que SÍ canjearon con él. Hoy esa relación no existe, así que no se abre nada.)
create policy users_select_own on public.users
  for select to authenticated
  using (id = (select auth.uid()) or app.is_platform_admin());

create policy users_insert_own on public.users
  for insert to authenticated
  with check (id = (select auth.uid()) or app.is_platform_admin());

create policy users_update_own on public.users
  for update to authenticated
  using (id = (select auth.uid()) or app.is_platform_admin())
  with check (id = (select auth.uid()) or app.is_platform_admin());

create policy users_delete_admin on public.users
  for delete to authenticated
  using (app.is_platform_admin());

-- merchants: el usuario final ve la red activa; la cuenta de un local se ve solo a sí misma.
create policy merchants_select on public.merchants
  for select to authenticated
  using (
    app.is_platform_admin()
    or id = app.current_merchant_id()
    or (activo and app.current_merchant_id() is null)
  );

-- Tres políticas y no un `for all`: si el admin entrara también por SELECT se evaluarían dos
-- políticas permisivas en cada lectura, y la ruleta lee esto en cada carga.
create policy merchants_insert_admin on public.merchants
  for insert to authenticated
  with check (app.is_platform_admin());

create policy merchants_update_admin on public.merchants
  for update to authenticated
  using (app.is_platform_admin())
  with check (app.is_platform_admin());

create policy merchants_delete_admin on public.merchants
  for delete to authenticated
  using (app.is_platform_admin());

-- merchant_users: el local ve a su propia gente. Darla de alta es del admin (T12).
create policy merchant_users_select on public.merchant_users
  for select to authenticated
  using (app.is_platform_admin() or merchant_id = app.current_merchant_id());

-- Tres políticas y no un `for all`: si el admin entrara también por SELECT se evaluarían dos
-- políticas permisivas en cada lectura, y la ruleta lee esto en cada carga.
create policy merchant_users_insert_admin on public.merchant_users
  for insert to authenticated
  with check (app.is_platform_admin());

create policy merchant_users_update_admin on public.merchant_users
  for update to authenticated
  using (app.is_platform_admin())
  with check (app.is_platform_admin());

create policy merchant_users_delete_admin on public.merchant_users
  for delete to authenticated
  using (app.is_platform_admin());

-- ---------------------------------------------------------------------------
-- Semilla de parámetros (docs/seed-data.md)
-- ---------------------------------------------------------------------------

insert into public.settings (key, value, tipo, descripcion) values
  ('cooldown_dias_default',     '3',    'entero',  'Días que un comercio se apaga para el usuario tras validarle un canje, si el comercio no define el suyo.'),
  ('ttl_codigo_canje_minutos',  '5',    'entero',  'Minutos que vive un canje pendiente antes de expirar y liberar el giro.'),
  ('canjes_nivel_1',            '10',   'entero',  'Canjes validados para desbloquear la tarjeta Nivel 1.'),
  ('canjes_nivel_2',            '35',   'entero',  'Canjes validados para desbloquear la tarjeta Nivel 2.'),
  ('canjes_premium',            '100',  'entero',  'Canjes validados para desbloquear la tarjeta Premium.'),
  ('giros_extra_nivel_1',       '2',    'entero',  'Giros extra por ciclo para el portador de la tarjeta Nivel 1.'),
  ('giros_extra_nivel_2',       '4',    'entero',  'Giros extra por ciclo para el portador de la tarjeta Nivel 2.'),
  ('giros_extra_premium',       '6',    'entero',  'Giros extra por ciclo para el portador de la tarjeta Premium.'),
  ('giros_suscripcion_mensual', '8',    'entero',  'Giros por ciclo de la suscripción mensual. No se acumulan entre ciclos.'),
  ('giros_suscripcion_anual',   '10',   'entero',  'Giros por ciclo de la suscripción anual. No se acumulan entre ciclos.'),
  ('comision_giftcard',         '0.10', 'decimal', 'Comisión del comercio por giftcard vendida.');
