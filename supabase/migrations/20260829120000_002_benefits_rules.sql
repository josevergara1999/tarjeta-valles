-- Migración 002 — Beneficios: benefits, benefit_rules
-- Hito 1 · T2. Referencias: docs/decisiones-hito-1.md (manda sobre el spec), docs/spec-app-tarjeta.md.
--
-- Acá vive el QUÉ ofrece cada comercio y CUÁNDO. El cálculo de si una casilla está disponible para
-- un usuario concreto NO está acá: es T4 (`get_available_benefits`), y esa función es su única
-- fuente de verdad. Esta migración solo garantiza que los datos con los que T4 va a razonar sean
-- coherentes: sin ventanas a medias, sin topes imposibles, sin dos beneficios activos por comercio.

-- ---------------------------------------------------------------------------
-- Tipos
-- ---------------------------------------------------------------------------

create type public.benefit_tipo as enum ('cortesia', 'descuento');

-- ---------------------------------------------------------------------------
-- benefits — las casillas de la ruleta. Una activa por comercio (decisión 4).
-- ---------------------------------------------------------------------------

create table public.benefits (
  id                uuid primary key default gen_random_uuid(),
  merchant_id       uuid not null references public.merchants (id) on delete cascade,
  tipo              public.benefit_tipo not null,
  titulo            text not null,
  condicion_consumo text,
  descripcion       text,
  activo            boolean not null default true,
  created_at        timestamptz not null default now(),

  constraint benefits_titulo_no_vacio
    check (length(btrim(titulo)) > 0),

  -- Nulo significa "este beneficio no tiene condición" (los casos #3, #5 y #7 de seed-data.md).
  -- La cadena vacía no: dejaría a la interfaz dibujando una etiqueta colgando sin texto, y la regla
  -- dura del proyecto es que el beneficio y su condición se muestran siempre juntos.
  constraint benefits_condicion_no_vacia
    check (condicion_consumo is null or length(btrim(condicion_consumo)) > 0)
);

comment on table public.benefits is
  'Beneficio que ofrece un comercio. Solo uno puede estar activo a la vez por comercio (decisión 4): el mesón no aguanta ambigüedad.';

comment on column public.benefits.condicion_consumo is
  'La letra chica que SIEMPRE se muestra junto al título ("con la segunda ronda"). Nulo = el beneficio no tiene condición.';

-- La decisión 4 en una línea: el modelo admite varios beneficios por comercio (históricos,
-- borradores), pero activo solo puede haber uno. Parcial, para no estorbar a los inactivos.
create unique index benefits_uno_activo_por_merchant
  on public.benefits (merchant_id)
  where activo;

create index benefits_merchant_idx on public.benefits (merchant_id);

-- ---------------------------------------------------------------------------
-- benefit_rules — cuándo y cuántos. 1:1 con benefits.
--
-- Sin `cooldown_dias`: la decisión 3 lo movió a `merchants`, porque la regla de producto es "ese
-- local se apaga", no "ese beneficio se apaga". Vive ahí desde la 001.
-- ---------------------------------------------------------------------------

-- Validar `dias_semana` dentro del CHECK no alcanza con operadores sueltos: `<@` deja pasar
-- duplicados ({1,1}) y array_length devuelve NULL para el array vacío, con lo que un CHECK ingenuo
-- lo aceptaría (un CHECK solo falla cuando da FALSE, no cuando da NULL).
create function app.dias_semana_validos(p_dias smallint[])
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_dias is not null
     and cardinality(p_dias) between 1 and 7
     and p_dias <@ array[0,1,2,3,4,5,6]::smallint[]
     and cardinality(p_dias) = (select count(distinct d) from unnest(p_dias) as d);
$$;

comment on function app.dias_semana_validos(smallint[]) is
  'Días válidos, sin repetidos y sin array vacío. Convención: 0=domingo … 6=sábado, la misma que devuelve extract(dow).';

create table public.benefit_rules (
  benefit_id   uuid primary key references public.benefits (id) on delete cascade,
  cupos_dia    integer,
  cupos_semana integer,
  dias_semana  smallint[] not null default '{0,1,2,3,4,5,6}',
  hora_inicio  time,
  hora_fin     time,
  updated_at   timestamptz not null default now(),

  constraint benefit_rules_cupos_dia_positivo
    check (cupos_dia is null or cupos_dia > 0),
  constraint benefit_rules_cupos_semana_positivo
    check (cupos_semana is null or cupos_semana > 0),

  -- Un tope semanal menor que el diario es siempre un error de carga: el diario no se alcanzaría nunca.
  constraint benefit_rules_cupos_coherentes
    check (cupos_dia is null or cupos_semana is null or cupos_semana >= cupos_dia),

  constraint benefit_rules_dias_validos
    check (app.dias_semana_validos(dias_semana)),

  -- Ventana nula = todo el día (el caso #6, el late checkout del hospedaje). Media ventana no
  -- significa nada, así que o están las dos horas o no está ninguna.
  constraint benefit_rules_ventana_completa
    check ((hora_inicio is null) = (hora_fin is null)),

  -- hora_inicio = hora_fin sería ambiguo: ¿ventana de cero minutos o de 24 horas? Se prohíbe para
  -- que T4 nunca tenga que adivinar. Para "todo el día" van las dos horas en nulo.
  constraint benefit_rules_ventana_no_degenerada
    check (hora_inicio is null or hora_inicio <> hora_fin)
);

comment on table public.benefit_rules is
  'Cupos y horarios de un beneficio. Quien los interpreta es T4, en America/Santiago y en un solo lugar.';

comment on column public.benefit_rules.cupos_dia is
  'Nulo = sin tope. El conteo (validados + pendientes vigentes) lo hace T4, no esta tabla.';

comment on column public.benefit_rules.dias_semana is
  'Días en que la ventana ABRE. 0=domingo … 6=sábado. Si hora_fin < hora_inicio la ventana cruza medianoche y la madrugada siguiente sigue perteneciendo al día en que abrió (decisión 6).';

comment on column public.benefit_rules.hora_fin is
  'Puede ser MENOR que hora_inicio: la cervecería de 21:00 a 02:00 es un caso real, no un error de carga (decisión 6).';

-- El spec dice 1:1 y conviene que lo sea de verdad: si un beneficio pudiera existir sin reglas, T4
-- tendría que inventarse valores por defecto, y eso sería un segundo lugar donde vive la regla.
-- Mismo patrón que merchant_secrets en la 001.
create function app.benefit_rules_autocreate()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.benefit_rules (benefit_id) values (new.id);
  return new;
end;
$$;

create trigger benefits_rules_autocreate
  after insert on public.benefits
  for each row execute function app.benefit_rules_autocreate();

comment on function app.benefit_rules_autocreate() is
  'Todo beneficio nace con su fila de reglas: sin tope, todos los días, todo el día. El comercio la ajusta en T11.';

-- ---------------------------------------------------------------------------
-- Helpers de RLS
--
-- SECURITY DEFINER a propósito: una subconsulta dentro de una política se evalúa con el RLS de la
-- tabla consultada, y encadenar políticas entre tablas se vuelve frágil y lento. Estas tres
-- responden lo mínimo, saltándose ese enredo.
-- ---------------------------------------------------------------------------

create function app.merchant_activo(p_merchant_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select m.activo from public.merchants m where m.id = p_merchant_id), false);
$$;

create function app.benefit_merchant_id(p_benefit_id uuid)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select b.merchant_id from public.benefits b where b.id = p_benefit_id;
$$;

create function app.benefit_publico(p_benefit_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((
    select b.activo and m.activo
    from public.benefits b
    join public.merchants m on m.id = b.merchant_id
    where b.id = p_benefit_id
  ), false);
$$;

grant execute on function
  app.dias_semana_validos(smallint[]),
  app.merchant_activo(uuid),
  app.benefit_merchant_id(uuid),
  app.benefit_publico(uuid)
  to authenticated;

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------

alter table public.benefits      enable row level security;
alter table public.benefit_rules enable row level security;

-- benefits: el usuario final ve los beneficios activos de la red activa —incluidos los que hoy
-- están agotados o en cooldown, porque esas casillas se muestran APAGADAS, no ocultas—. La cuenta
-- de un local ve solo el suyo, igual que en merchants: no puede espiar la oferta del vecino.
create policy benefits_select on public.benefits
  for select to authenticated
  using (
    app.is_platform_admin()
    or merchant_id = app.current_merchant_id()
    or (activo and app.current_merchant_id() is null and app.merchant_activo(merchant_id))
  );

-- El local edita su propio beneficio (T11). El WITH CHECK es lo que impide que se lo cuelgue a otro.
create policy benefits_insert on public.benefits
  for insert to authenticated
  with check (app.is_platform_admin() or merchant_id = app.current_merchant_id());

create policy benefits_update on public.benefits
  for update to authenticated
  using (app.is_platform_admin() or merchant_id = app.current_merchant_id())
  with check (app.is_platform_admin() or merchant_id = app.current_merchant_id());

-- Borrar no: un beneficio con canjes a la espalda se apaga con `activo = false`, no se destruye.
create policy benefits_delete_admin on public.benefits
  for delete to authenticated
  using (app.is_platform_admin());

-- benefit_rules: mismas audiencias, alcanzadas a través del beneficio.
create policy benefit_rules_select on public.benefit_rules
  for select to authenticated
  using (
    app.is_platform_admin()
    or app.benefit_merchant_id(benefit_id) = app.current_merchant_id()
    or (app.current_merchant_id() is null and app.benefit_publico(benefit_id))
  );

create policy benefit_rules_insert on public.benefit_rules
  for insert to authenticated
  with check (
    app.is_platform_admin()
    or app.benefit_merchant_id(benefit_id) = app.current_merchant_id()
  );

create policy benefit_rules_update on public.benefit_rules
  for update to authenticated
  using (
    app.is_platform_admin()
    or app.benefit_merchant_id(benefit_id) = app.current_merchant_id()
  )
  with check (
    app.is_platform_admin()
    or app.benefit_merchant_id(benefit_id) = app.current_merchant_id()
  );

create policy benefit_rules_delete_admin on public.benefit_rules
  for delete to authenticated
  using (app.is_platform_admin());

-- ---------------------------------------------------------------------------
-- Semilla — los 8 comercios de docs/seed-data.md
--
-- DATOS DE PRUEBA, INVENTADOS. Ningún nombre corresponde a un local real de Las Trancas: usarlos
-- sin autorización firmada no está permitido, y el repositorio es público.
--
-- Los identificadores son fijos y reconocibles a propósito (`5eed…` = seed) para poder barrerlos de
-- una sola pasada el día que entren comercios de verdad, sin tocar nada más:
--
--   delete from public.merchants where id::text like '5eed0000-%';
--
-- Ese borrado arrastra en cascada los beneficios, sus reglas y los secretos de firma.
-- ---------------------------------------------------------------------------

insert into public.merchants (id, nombre, rubro, activo) values
  ('5eed0000-0000-4000-a000-000000000001', 'Fogón del Valle',    'restaurante', true),
  ('5eed0000-0000-4000-a000-000000000002', 'Cervecería Nevado',  'cerveceria',  true),
  ('5eed0000-0000-4000-a000-000000000003', 'Café Bosque',        'restaurante', true),
  ('5eed0000-0000-4000-a000-000000000004', 'Rental Trancas',     'rental',      true),
  ('5eed0000-0000-4000-a000-000000000005', 'Minimarket El Paso', 'minimarket',  true),
  ('5eed0000-0000-4000-a000-000000000006', 'Cabañas Mirador',    'hospedaje',   true),
  ('5eed0000-0000-4000-a000-000000000007', 'Termas del Sur',     'otro',        true),
  ('5eed0000-0000-4000-a000-000000000008', 'Gimnasio Andino',    'gimnasio',    true);

-- `cooldown_dias` queda en nulo en los ocho: heredan settings.cooldown_dias_default = 3. Es lo que
-- hace que el escenario 4 de seed-data.md dé "Vuelve en 2 días" para quien canjeó ayer.

insert into public.benefits (id, merchant_id, tipo, titulo, condicion_consumo) values
  ('5eedbe11-0000-4000-a000-000000000001', '5eed0000-0000-4000-a000-000000000001', 'cortesia',  'Postre de cortesía',    'con plato principal'),
  ('5eedbe11-0000-4000-a000-000000000002', '5eed0000-0000-4000-a000-000000000002', 'cortesia',  'Schop de cortesía',     'con la segunda ronda'),
  ('5eedbe11-0000-4000-a000-000000000003', '5eed0000-0000-4000-a000-000000000003', 'descuento', '15% en la cuenta',      null),
  ('5eedbe11-0000-4000-a000-000000000004', '5eed0000-0000-4000-a000-000000000004', 'descuento', '15% en el arriendo',    'arriendo de día completo'),
  ('5eedbe11-0000-4000-a000-000000000005', '5eed0000-0000-4000-a000-000000000005', 'descuento', '10% en la compra',      'compras sobre $15.000'),
  ('5eedbe11-0000-4000-a000-000000000006', '5eed0000-0000-4000-a000-000000000006', 'cortesia',  'Late checkout 14:00',   'sujeto a disponibilidad'),
  ('5eedbe11-0000-4000-a000-000000000007', '5eed0000-0000-4000-a000-000000000007', 'descuento', '20% en la entrada',     null),
  ('5eedbe11-0000-4000-a000-000000000008', '5eed0000-0000-4000-a000-000000000008', 'cortesia',  'Clase grupal incluida', null);

-- Las filas de reglas ya existen: las creó el trigger con el valor permisivo por defecto. Acá se
-- ajustan a los datos de la tabla de seed-data.md, de ahí el ON CONFLICT.
insert into public.benefit_rules (benefit_id, cupos_dia, dias_semana, hora_inicio, hora_fin) values
  ('5eedbe11-0000-4000-a000-000000000001',    6, '{1,2,3,4}',     '12:00', '16:00'),  -- Lun-Jue
  ('5eedbe11-0000-4000-a000-000000000002',   10, '{0,2,3,4,5,6}', '17:00', '21:00'),  -- Mar-Dom
  ('5eedbe11-0000-4000-a000-000000000003', null, '{0,1,2,3,4,5,6}', '08:00', '13:00'),
  ('5eedbe11-0000-4000-a000-000000000004',    8, '{0,1,2,3,4,5,6}', '08:00', '12:00'),
  ('5eedbe11-0000-4000-a000-000000000005', null, '{0,1,2,3,4,5,6}', '09:00', '21:00'),
  ('5eedbe11-0000-4000-a000-000000000006',    2, '{0,1,2,3,4,5,6}',   null,   null),  -- sin ventana: todo el día
  ('5eedbe11-0000-4000-a000-000000000007',   15, '{1,2,3,4,5}',   '10:00', '18:00'),  -- Lun-Vie
  ('5eedbe11-0000-4000-a000-000000000008',    4, '{1,2,3,4,5}',   '07:00', '20:00')   -- Lun-Vie
on conflict (benefit_id) do update set
  cupos_dia   = excluded.cupos_dia,
  dias_semana = excluded.dias_semana,
  hora_inicio = excluded.hora_inicio,
  hora_fin    = excluded.hora_fin,
  updated_at  = now();

-- `cupos_semana` queda en nulo en los ocho: seed-data.md solo fija topes diarios. Los casos #3 y #5
-- van sin tope de ningún tipo, que es justo lo que hay que poder probar.
