-- Migración 005 — Giros y canjes: entitlements, redemptions
-- Hito 1 · T3. Referencias: docs/decisiones-hito-1.md (manda sobre el spec), docs/spec-app-tarjeta.md.
--
-- `redemptions` es la tabla más importante del sistema y la que sostiene la regla antifraude: el
-- giro se RESERVA cuando el usuario elige y se DESCUENTA cuando el comercio valida. Acá van las
-- restricciones que hacen imposible saltarse eso; el flujo en sí es T5 y T6.
--
-- Nada de esta migración abre escritura por la API para el flujo de canje. Crear, cancelar y
-- validar canjes se hará con funciones SECURITY DEFINER (T5, T6), porque la reserva necesita una
-- transacción con lock y eso no se puede expresar en una política de RLS.

-- ---------------------------------------------------------------------------
-- Tipos
-- ---------------------------------------------------------------------------

create type public.entitlement_tipo as enum (
  'bienvenida', 'pase_dia', 'pase_3', 'pase_7', 'pase_14',
  'suscripcion_mensual', 'suscripcion_anual'
);

create type public.entitlement_estado as enum (
  'pendiente_activacion', 'activo', 'expirado', 'cancelado'
);

create type public.redemption_estado as enum (
  'pendiente', 'validado', 'expirado', 'anulado'
);

-- ---------------------------------------------------------------------------
-- entitlements — la billetera de giros del usuario.
--
-- Sin `order_id` ni `giftcard_id`: `orders` y `giftcards` son del Hito 2 y del 4. Una columna uuid
-- sin clave foránea que la respalde es una referencia rota esperando su turno, así que se agregan
-- cuando existan esas tablas. En el Hito 1 los giros los carga el admin a mano (T12).
-- ---------------------------------------------------------------------------

create table public.entitlements (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid not null references public.users (id) on delete cascade,
  tipo             public.entitlement_tipo not null,
  giros_totales    integer not null,
  giros_usados     integer not null default 0,
  estado           public.entitlement_estado not null default 'pendiente_activacion',
  fecha_compra     timestamptz not null default now(),
  fecha_activacion timestamptz,
  fecha_expiracion timestamptz,
  created_at       timestamptz not null default now(),

  constraint entitlements_giros_totales_positivo check (giros_totales > 0),
  constraint entitlements_giros_usados_no_negativo check (giros_usados >= 0),

  -- La barrera de saldo. Que nadie gaste más giros de los que compró no puede depender de que el
  -- código se acuerde de comprobarlo.
  constraint entitlements_saldo check (giros_usados <= giros_totales),

  -- Un pase se activa con el primer canje o con el botón (spec 3.3): desde ahí corren los días.
  -- Un entitlement activo sin fecha de activación no tendría desde cuándo contar.
  constraint entitlements_activo_tiene_activacion
    check (estado <> 'activo' or fecha_activacion is not null),

  constraint entitlements_expira_despues_de_activarse
    check (fecha_expiracion is null or fecha_activacion is null
           or fecha_expiracion > fecha_activacion)
);

comment on table public.entitlements is
  'Billetera de giros. Los giros no usados se pierden al expirar: no se devuelven ni se transfieren (spec 3.3).';

comment on column public.entitlements.giros_usados is
  'Sube cuando el comercio VALIDA (T6), nunca cuando el usuario elige. Una reserva pendiente no se cuenta acá: se cuenta mirando redemptions.';

-- Decisión 10: el giro de bienvenida es uno por usuario y de por vida. No uno por local escaneado.
create unique index entitlements_bienvenida_unica
  on public.entitlements (user_id)
  where tipo = 'bienvenida';

create index entitlements_user_estado_idx on public.entitlements (user_id, estado);

-- ---------------------------------------------------------------------------
-- redemptions — los canjes.
-- ---------------------------------------------------------------------------

-- `redemptions` guarda benefit_id Y merchant_id, que es lo que quiere el spec porque el panel del
-- comercio filtra por merchant_id en cada pantalla. Pero denormalizar así abre la puerta a una fila
-- donde el beneficio es de un local y el canje figura en otro. Esta unicidad —redundante contra la
-- clave primaria, pero necesaria para poder referenciarla— permite una foránea compuesta que lo
-- vuelve imposible desde la base, sin depender de que T5 se acuerde.
alter table public.benefits
  add constraint benefits_id_merchant_unico unique (id, merchant_id);

create table public.redemptions (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references public.users (id) on delete cascade,
  entitlement_id  uuid not null references public.entitlements (id) on delete restrict,
  benefit_id      uuid not null,
  merchant_id     uuid not null references public.merchants (id) on delete restrict,
  codigo          text not null,
  estado          public.redemption_estado not null default 'pendiente',
  created_at      timestamptz not null default now(),
  expira_at       timestamptz not null,
  validado_at     timestamptz,
  validado_por    uuid references public.merchant_users (id) on delete set null,
  motivo_anulacion text,
  anulado_por     uuid references auth.users (id) on delete set null,

  -- El beneficio canjeado tiene que ser de ese comercio. Es el escenario 9 de seed-data.md
  -- ("Nevado no puede validar un código generado para Fogón") cerrado en la base: T6 lo comprobará
  -- igual, pero acá ni siquiera se puede escribir la fila incoherente.
  constraint redemptions_benefit_es_del_merchant
    foreign key (benefit_id, merchant_id)
    references public.benefits (id, merchant_id) on delete restrict,

  -- Seis dígitos, ni más ni menos: es lo que se teclea en el mesón cuando el QR no se deja leer.
  constraint redemptions_codigo_formato check (codigo ~ '^[0-9]{6}$'),

  constraint redemptions_expira_despues_de_crearse check (expira_at > created_at),

  -- Un canje validado sin hora de validación dejaría al cooldown sin desde cuándo contar
  -- (decisión 3: corre desde validado_at).
  constraint redemptions_validado_tiene_hora
    check (estado <> 'validado' or validado_at is not null),

  -- La anulación es manual y de soporte: sin motivo y sin responsable no se anula nada.
  constraint redemptions_anulado_tiene_motivo
    check (estado <> 'anulado'
           or (anulado_por is not null
               and motivo_anulacion is not null
               and length(btrim(motivo_anulacion)) > 0)),

  -- Y al revés: un canje que no está anulado no puede arrastrar motivo de anulación.
  constraint redemptions_motivo_solo_si_anulado
    check (estado = 'anulado' or (motivo_anulacion is null and anulado_por is null))
);

comment on table public.redemptions is
  'Canjes. El giro se reserva al crear (estado pendiente) y se descuenta al validar. Un pendiente expirado libera el giro solo: la expiración se evalúa al vuelo comparando expira_at, nunca con un cron (decisión 8).';

comment on column public.redemptions.validado_por is
  'Nulo tolerado: en el modo de contingencia del Hito 5 el canje se sincroniza sin saber qué cuenta del local lo validó.';

comment on column public.redemptions.expira_at is
  'created_at + settings.ttl_codigo_canje_minutos. El TTL se lee de settings, nunca se hardcodea.';

-- Unicidad del código mientras está vigente (decisión: menores). Los códigos históricos pueden
-- repetirse: seis dígitos se agotan rápido y un canje ya validado no se puede volver a usar.
create unique index redemptions_codigo_pendiente_unico
  on public.redemptions (codigo)
  where estado = 'pendiente';

-- Decisión 2: máximo un canje pendiente por usuario. Nadie está en dos locales a la vez.
--
-- El índice no puede mirar expira_at (no es inmutable), así que es más estricto que la regla: un
-- pendiente ya vencido pero sin marcar también bloquea. Es a propósito. T5 tiene que barrer los
-- vencidos del usuario antes de insertar, y así el estado en la base nunca queda a medio camino.
create unique index redemptions_un_pendiente_por_usuario
  on public.redemptions (user_id)
  where estado = 'pendiente';

-- Para el conteo de cupos de T4: validados + pendientes vigentes de un beneficio.
create index redemptions_benefit_estado_idx on public.redemptions (benefit_id, estado, created_at);

-- Para el cooldown de T4: última validación de ese usuario en ese comercio.
create index redemptions_cooldown_idx on public.redemptions (user_id, merchant_id, validado_at);

-- Para el "Hoy" del panel del comercio (T11).
create index redemptions_merchant_fecha_idx on public.redemptions (merchant_id, created_at);

create index redemptions_entitlement_idx on public.redemptions (entitlement_id);

-- ---------------------------------------------------------------------------
-- Helpers de RLS
-- ---------------------------------------------------------------------------

-- La 001 dejó esto anotado: "en T3 se agrega la política que deja al comercio ver a los usuarios
-- que SÍ canjearon con él". Es esa función.
create function app.usuario_canjeo_en(p_user_id uuid, p_merchant_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_merchant_id is not null and exists (
    select 1 from public.redemptions r
    where r.user_id = p_user_id
      and r.merchant_id = p_merchant_id
      and r.estado in ('pendiente', 'validado')
  );
$$;

comment on function app.usuario_canjeo_en(uuid, uuid) is
  'El comercio ve al cliente que tiene un canje con él, vigente o ya validado. Un canje anulado o expirado no da acceso a nada.';

grant execute on function app.usuario_canjeo_en(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------

alter table public.entitlements enable row level security;
alter table public.redemptions  enable row level security;

-- entitlements: cada uno ve su billetera. El comercio no tiene por qué saber cuántos giros le
-- quedan a quien tiene enfrente, y menos qué compró.
create policy entitlements_select_own on public.entitlements
  for select to authenticated
  using (user_id = (select auth.uid()) or app.is_platform_admin());

-- Escribir es del admin (T12: carga manual de giros). El giro de bienvenida de T7 y el descuento
-- al validar de T6 pasarán por funciones SECURITY DEFINER, no por estas políticas.
create policy entitlements_insert_admin on public.entitlements
  for insert to authenticated
  with check (app.is_platform_admin());

create policy entitlements_update_admin on public.entitlements
  for update to authenticated
  using (app.is_platform_admin())
  with check (app.is_platform_admin());

create policy entitlements_delete_admin on public.entitlements
  for delete to authenticated
  using (app.is_platform_admin());

-- redemptions: el usuario ve los suyos; el comercio, los de su local y ninguno más. Es el
-- escenario 7 de seed-data.md, el que dice que Fogón no puede leer los canjes de Nevado.
create policy redemptions_select on public.redemptions
  for select to authenticated
  using (
    app.is_platform_admin()
    or user_id = (select auth.uid())
    or merchant_id = app.current_merchant_id()
  );

-- Ninguna política de escritura para el flujo normal, y es deliberado.
--
-- Reservar exige comprobar cupos y saldo dentro de una transacción con lock (decisión 1): dos
-- usuarios simultáneos pasarían ambos un chequeo previo. Eso no se expresa en un WITH CHECK, así
-- que crear, cancelar y validar viven en funciones SECURITY DEFINER (T5, T6). Lo único que se abre
-- acá es la anulación manual de soporte, que es del admin (T12).
create policy redemptions_insert_admin on public.redemptions
  for insert to authenticated
  with check (app.is_platform_admin());

create policy redemptions_update_admin on public.redemptions
  for update to authenticated
  using (app.is_platform_admin())
  with check (app.is_platform_admin());

create policy redemptions_delete_admin on public.redemptions
  for delete to authenticated
  using (app.is_platform_admin());

-- Y la política que la 001 dejó pendiente: el comercio ve a sus clientes, solo a los suyos.
-- Convive con users_select_own como segunda política permisiva; es el precio de que el local pueda
-- poner nombre al canje que está validando.
create policy users_select_clientes_del_comercio on public.users
  for select to authenticated
  using (app.usuario_canjeo_en(id, app.current_merchant_id()));

-- ---------------------------------------------------------------------------
-- Semilla — los 5 usuarios de docs/seed-data.md
--
-- DATOS DE PRUEBA. Los teléfonos son los ficticios de seed-data.md y las filas de `auth.users` se
-- escriben a mano: **estos usuarios no pueden iniciar sesión**, porque no tienen identidad ni
-- credencial. Sirven para probar T4, T5 y T6 contra datos realistas. Los usuarios de verdad los
-- creará el OTP en T7.
--
-- Cuánto vale cada producto en giros NO está definido en ninguna parte: los productos son del
-- Hito 2, y lo único fijado hoy es la suscripción (8 mensual / 10 anual, en `settings`) y el pase
-- de 14 días = 12 giros. Los `giros_totales` de los pases de acá son **relleno de prueba**, no una
-- decisión de producto: el pase de 7 días con 8 giros y el de 3 días con 4 hay que confirmarlos
-- cuando se defina la tabla de productos.
--
-- Para barrer la semilla entera hay que respetar el orden, porque `redemptions` referencia comercios
-- y beneficios con ON DELETE RESTRICT justamente para que el historial no se borre por accidente:
--
--   delete from public.redemptions  where user_id::text like '5eed0002-%';
--   delete from public.entitlements where user_id::text like '5eed0002-%';
--   delete from auth.users          where id::text      like '5eed0002-%';
--   delete from public.merchants    where id::text      like '5eed0000-%';
-- ---------------------------------------------------------------------------

insert into auth.users (id, instance_id, aud, role, phone, phone_confirmed_at, created_at, updated_at)
values
  ('5eed0002-0000-4000-a000-000000000001', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '+56911111111', now(), now(), now()),
  ('5eed0002-0000-4000-a000-000000000002', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '+56922222222', now(), now(), now()),
  ('5eed0002-0000-4000-a000-000000000003', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '+56933333333', now(), now(), now()),
  ('5eed0002-0000-4000-a000-000000000004', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '+56944444444', now(), now(), now()),
  ('5eed0002-0000-4000-a000-000000000005', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '+56955555555', now(), now(), now());

insert into public.users (id, telefono, nombre) values
  ('5eed0002-0000-4000-a000-000000000001', '+56911111111', 'Turista nuevo'),
  ('5eed0002-0000-4000-a000-000000000002', '+56922222222', 'Turista con pase'),
  ('5eed0002-0000-4000-a000-000000000003', '+56933333333', 'Suscriptora'),
  ('5eed0002-0000-4000-a000-000000000004', '+56944444444', 'Cliente Nivel 1'),
  ('5eed0002-0000-4000-a000-000000000005', '+56955555555', 'Pase vencido');

-- El usuario 1 se queda sin entitlements a propósito: es el que prueba el onboarding y el giro de
-- bienvenida de T7. Si naciera con giros, esa prueba no existiría.
insert into public.entitlements
  (id, user_id, tipo, giros_totales, giros_usados, estado, fecha_activacion, fecha_expiracion)
values
  -- Turista con pase de 7 días, 3 giros usados y 2 canjes recientes que lo dejan en cooldown.
  ('5eed0003-0000-4000-a000-000000000002', '5eed0002-0000-4000-a000-000000000002',
   'pase_7', 8, 3, 'activo', now() - interval '4 days', now() + interval '3 days'),

  -- Suscriptora: un ciclo vencido con giros que se perdieron (spec 3.3) y el ciclo actual en curso.
  ('5eed0003-0000-4000-a000-000000000031', '5eed0002-0000-4000-a000-000000000003',
   'suscripcion_mensual', 8, 3, 'expirado', now() - interval '90 days', now() - interval '60 days'),
  ('5eed0003-0000-4000-a000-000000000032', '5eed0002-0000-4000-a000-000000000003',
   'suscripcion_mensual', 8, 5, 'activo', now() - interval '20 days', now() + interval '10 days'),

  -- Nivel 1: cuatro ciclos cerrados más el actual. 8+8+8+6+4 = 34 canjes históricos.
  ('5eed0003-0000-4000-a000-000000000041', '5eed0002-0000-4000-a000-000000000004',
   'suscripcion_mensual', 8, 8, 'expirado', now() - interval '400 days', now() - interval '370 days'),
  ('5eed0003-0000-4000-a000-000000000042', '5eed0002-0000-4000-a000-000000000004',
   'suscripcion_mensual', 8, 8, 'expirado', now() - interval '300 days', now() - interval '270 days'),
  ('5eed0003-0000-4000-a000-000000000043', '5eed0002-0000-4000-a000-000000000004',
   'suscripcion_mensual', 8, 8, 'expirado', now() - interval '200 days', now() - interval '170 days'),
  ('5eed0003-0000-4000-a000-000000000044', '5eed0002-0000-4000-a000-000000000004',
   'suscripcion_mensual', 8, 6, 'expirado', now() - interval '100 days', now() - interval '70 days'),
  ('5eed0003-0000-4000-a000-000000000045', '5eed0002-0000-4000-a000-000000000004',
   'suscripcion_mensual', 8, 4, 'activo', now() - interval '15 days', now() + interval '15 days'),

  -- Pase vencido con un giro sin usar: se perdió, y esa es justamente la prueba.
  ('5eed0003-0000-4000-a000-000000000005', '5eed0002-0000-4000-a000-000000000005',
   'pase_3', 4, 3, 'expirado', now() - interval '30 days', now() - interval '27 days');

-- Los 3 canjes del turista. Los dos primeros son recientes: con cooldown_dias_default = 3 dejan
-- esos dos locales apagados, que es el escenario 4 de seed-data.md ("Vuelve en 2 días").
insert into public.redemptions
  (user_id, entitlement_id, benefit_id, merchant_id, codigo, estado, created_at, expira_at, validado_at)
values
  ('5eed0002-0000-4000-a000-000000000002', '5eed0003-0000-4000-a000-000000000002',
   '5eedbe11-0000-4000-a000-000000000002', '5eed0000-0000-4000-a000-000000000002',
   '100001', 'validado', now() - interval '1 day', now() - interval '1 day' + interval '5 minutes',
   now() - interval '1 day' + interval '2 minutes'),
  ('5eed0002-0000-4000-a000-000000000002', '5eed0003-0000-4000-a000-000000000002',
   '5eedbe11-0000-4000-a000-000000000001', '5eed0000-0000-4000-a000-000000000001',
   '100002', 'validado', now() - interval '2 days', now() - interval '2 days' + interval '5 minutes',
   now() - interval '2 days' + interval '2 minutes'),
  ('5eed0002-0000-4000-a000-000000000002', '5eed0003-0000-4000-a000-000000000002',
   '5eedbe11-0000-4000-a000-000000000003', '5eed0000-0000-4000-a000-000000000003',
   '100003', 'validado', now() - interval '20 days', now() - interval '20 days' + interval '5 minutes',
   now() - interval '20 days' + interval '2 minutes');

-- El historial del resto. Todo suficientemente atrás como para no dejar a nadie en cooldown: lo que
-- se está sembrando acá es progreso acumulado, no canjes recientes.
do $$
declare
  v_benefits  uuid[];
  v_merchants uuid[];
  rec         record;
  i           int;
  v_creado    timestamptz;
begin
  select array_agg(b.id order by b.id), array_agg(b.merchant_id order by b.id)
    into v_benefits, v_merchants
  from public.benefits b
  where b.id::text like '5eedbe11-%';

  for rec in
    select * from (values
      ('5eed0002-0000-4000-a000-000000000003'::uuid, '5eed0003-0000-4000-a000-000000000031'::uuid, 3,  60),
      ('5eed0002-0000-4000-a000-000000000003'::uuid, '5eed0003-0000-4000-a000-000000000032'::uuid, 5,  12),
      ('5eed0002-0000-4000-a000-000000000004'::uuid, '5eed0003-0000-4000-a000-000000000041'::uuid, 8, 370),
      ('5eed0002-0000-4000-a000-000000000004'::uuid, '5eed0003-0000-4000-a000-000000000042'::uuid, 8, 270),
      ('5eed0002-0000-4000-a000-000000000004'::uuid, '5eed0003-0000-4000-a000-000000000043'::uuid, 8, 170),
      ('5eed0002-0000-4000-a000-000000000004'::uuid, '5eed0003-0000-4000-a000-000000000044'::uuid, 6,  70),
      ('5eed0002-0000-4000-a000-000000000004'::uuid, '5eed0003-0000-4000-a000-000000000045'::uuid, 4,   8),
      ('5eed0002-0000-4000-a000-000000000005'::uuid, '5eed0003-0000-4000-a000-000000000005'::uuid,  3,  28)
    ) as t(uid, eid, cuantos, dias)
  loop
    for i in 1..rec.cuantos loop
      v_creado := now() - ((rec.dias + i) * interval '1 day');
      insert into public.redemptions
        (user_id, entitlement_id, benefit_id, merchant_id, codigo, estado,
         created_at, expira_at, validado_at)
      values
        (rec.uid, rec.eid,
         v_benefits[1 + (i % 8)], v_merchants[1 + (i % 8)],
         lpad((200000 + (rec.dias * 10 + i))::text, 6, '0'),
         'validado', v_creado, v_creado + interval '5 minutes', v_creado + interval '2 minutes');
    end loop;
  end loop;
end $$;
