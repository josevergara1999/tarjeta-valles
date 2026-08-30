-- Migración 009 — `get_available_benefits`: la única fuente de verdad de la disponibilidad
-- Hito 1 · T4. Referencias: docs/decisiones-hito-1.md, docs/spec-app-tarjeta.md.
--
-- Esta es LA función del sistema. Todo lo que decide si una casilla de la ruleta se puede tocar
-- vive acá y en ningún otro lado. Si algún día aparece un cálculo de cupos, de cooldown o de
-- horarios en React, es un error: el cliente dibuja lo que esta función le devuelve y nada más.
--
-- Dos puertas sobre el usuario (saldo y ritmo) y cinco condiciones sobre cada beneficio.
-- T5 las vuelve a evaluar dentro de una transacción con lock antes de reservar: esto es lo que se
-- MUESTRA, aquello es lo que se COMPROMETE, y entre una lectura y la otra el mundo cambia.

-- ---------------------------------------------------------------------------
-- Qué canje "ocupa"
--
-- Un canje ocupa cupo, gasta franja y consume saldo si está validado o si está pendiente y todavía
-- no expira. Es la decisión 1 —validados + pendientes vigentes— y la 8: la expiración se evalúa al
-- vuelo comparando expira_at, sin cron que salga a limpiar.
--
-- Un `expirado` no ocupa (liberó su giro) y un `anulado` tampoco: la anulación devuelve el giro y
-- no cuenta para cupos ni para progreso.
-- ---------------------------------------------------------------------------

-- `stable` y no `immutable`, aunque no toque ninguna tabla: lee `now()`, y una función marcada
-- immutable puede ser evaluada una sola vez y reutilizada por el planificador. Un pendiente que
-- expira a mitad de la consulta seguiría contando como ocupado.
create function app.redemption_ocupa(p_estado public.redemption_estado, p_expira_at timestamptz)
returns boolean
language sql
stable
as $$
  select p_estado = 'validado'
      or (p_estado = 'pendiente' and p_expira_at > now());
$$;

comment on function app.redemption_ocupa(public.redemption_estado, timestamptz) is
  'Si este canje bloquea un cupo, una franja y un giro. Escrito una vez para que el conteo de cupos, el techo de ritmo y el saldo no puedan discrepar entre sí.';

-- ---------------------------------------------------------------------------
-- Saldo: giros realmente disponibles
--
-- No basta con `giros_totales - giros_usados`: `giros_usados` sube al VALIDAR (regla dura 3), así
-- que un canje pendiente todavía no aparece ahí aunque ya tenga el giro reservado. Sin restar los
-- pendientes vigentes, un usuario con un solo giro vería la ruleta abierta mientras tiene un código
-- esperando en el mesón.
--
-- `pendiente_activacion` suma: un pase se activa con el primer canje (spec 3.3), así que sus giros
-- están disponibles antes de activarse. Lo que no suma es lo expirado o cancelado.
-- ---------------------------------------------------------------------------

create function app.giros_disponibles(p_user_id uuid)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select greatest(
    coalesce((
      select sum(e.giros_totales - e.giros_usados)
      from public.entitlements e
      where e.user_id = p_user_id
        and e.estado in ('activo', 'pendiente_activacion')
        and (e.fecha_expiracion is null or e.fecha_expiracion > now())
    ), 0)
    - coalesce((
      select count(*)
      from public.redemptions r
      where r.user_id = p_user_id
        and r.estado = 'pendiente'
        and r.expira_at > now()
    ), 0),
    0
  )::integer;
$$;

comment on function app.giros_disponibles(uuid) is
  'Giros que el usuario puede gastar ahora mismo: los comprados y no usados, menos los que tiene reservados en un canje pendiente. El greatest(...,0) evita devolver negativos si un giro se anula de forma rara desde el panel admin.';

-- ---------------------------------------------------------------------------
-- Ritmo: qué franjas gastó hoy
-- ---------------------------------------------------------------------------

create function app.franja_gastada(p_user_id uuid, p_franja public.franja_dia, p_dia date)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.redemptions r
    where r.user_id = p_user_id
      and r.dia_operativo = p_dia
      and r.franja = p_franja
      and app.redemption_ocupa(r.estado, r.expira_at)
  );
$$;

create function app.canjes_del_dia(p_user_id uuid, p_dia date)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(count(*), 0)::integer
  from public.redemptions r
  where r.user_id = p_user_id
    and r.dia_operativo = p_dia
    and app.redemption_ocupa(r.estado, r.expira_at);
$$;

-- La hora a la que abre la franja siguiente, para que la pantalla pueda decir "vuelve a las 19:00"
-- en vez de mostrar una ruleta vacía sin explicación.
create function app.proxima_franja_at(p_ts timestamptz)
returns timestamptz
language sql
stable
security definer
set search_path = ''
as $$
  with horas as (
    select app.setting_text('franja_manana_inicio')::time as manana,
           app.setting_text('franja_tarde_inicio')::time  as tarde,
           app.setting_text('franja_noche_inicio')::time  as noche
  ),
  ahora as (
    select app.hora_local(p_ts) as h,
           (p_ts at time zone app.zona_horaria())::date as d
  )
  select (case
    -- Madrugada: la próxima franja es la mañana de hoy mismo.
    when a.h <  x.manana then (a.d + x.manana)
    when a.h <  x.tarde  then (a.d + x.tarde)
    when a.h <  x.noche  then (a.d + x.noche)
    -- Ya es de noche: la próxima es la mañana de mañana.
    else (a.d + 1 + x.manana)
  end) at time zone app.zona_horaria()
  from ahora a, horas x;
$$;

comment on function app.proxima_franja_at(timestamptz) is
  'Cuándo abre la siguiente franja. La devuelve el backend porque la regla de las franjas vive acá: el cliente no debe saber a qué hora empieza la noche.';

grant execute on function
  app.giros_disponibles(uuid),
  app.franja_gastada(uuid, public.franja_dia, date),
  app.canjes_del_dia(uuid, date),
  app.proxima_franja_at(timestamptz)
  to authenticated;

-- ---------------------------------------------------------------------------
-- get_turn_state — por qué la ruleta está como está
--
-- La regla dura del proyecto es que el cliente solo muestra lo que el backend le dice. Sin esta
-- función, T8 recibiría una lista vacía y no tendría con qué escribir "ya usaste tu giro de la
-- tarde, vuelve a las 19:00": terminaría calculando franjas en React, que es exactamente lo que
-- está prohibido. Es backend puro y no decide nada de diseño.
-- ---------------------------------------------------------------------------

create type public.turn_motivo as enum (
  'disponible',       -- puede girar
  'sin_giros',        -- no le quedan giros en ningún pase vigente
  'canje_pendiente',  -- ya tiene un código esperando en un mesón (decisión 2)
  'franja_gastada',   -- modo franjas: ya gastó esta etapa del día
  'techo_diario'      -- modo libre: llegó a giros_por_dia
);

create function public.get_turn_state()
returns table (
  motivo             public.turn_motivo,
  giros_disponibles  integer,
  franja_actual      public.franja_dia,
  dia_operativo      date,
  proxima_franja_at  timestamptz,
  canje_pendiente_id uuid,
  modo               text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user   uuid := (select auth.uid());
  v_ahora  timestamptz := now();
  v_franja public.franja_dia;
  v_dia    date;
  v_modo   text;
  v_giros  integer;
  v_pend   uuid;
begin
  if v_user is null then
    raise exception 'get_turn_state requiere sesión iniciada'
      using errcode = '28000';
  end if;

  v_franja := app.franja_en(v_ahora);
  v_dia    := app.dia_operativo(v_ahora);
  v_modo   := coalesce(app.setting_text('modo_ritmo_giros'), 'franjas');
  v_giros  := app.giros_disponibles(v_user);

  select r.id into v_pend
  from public.redemptions r
  where r.user_id = v_user
    and r.estado = 'pendiente'
    and r.expira_at > now()
  limit 1;

  motivo := (case
    -- El orden importa y es el de la experiencia, no el de la implementación: primero lo que el
    -- usuario puede resolver ahora (tiene un código abierto), después lo que no (no le quedan
    -- giros), y al final lo que solo se resuelve esperando.
    when v_pend is not null then 'canje_pendiente'
    when v_giros <= 0       then 'sin_giros'
    when v_modo = 'libre'
         and app.canjes_del_dia(v_user, v_dia)
             >= coalesce(app.setting_int('giros_por_dia'), 3) then 'techo_diario'
    when v_modo = 'franjas'
         and app.franja_gastada(v_user, v_franja, v_dia) then 'franja_gastada'
    else 'disponible'
  end)::public.turn_motivo;

  giros_disponibles  := v_giros;
  franja_actual      := v_franja;
  dia_operativo      := v_dia;
  proxima_franja_at  := app.proxima_franja_at(v_ahora);
  canje_pendiente_id := v_pend;
  modo               := v_modo;
  return next;
end;
$$;

comment on function public.get_turn_state() is
  'Estado del turno del usuario: si puede girar y, si no, por qué y hasta cuándo. Se lee siempre junto a get_available_benefits.';

-- ---------------------------------------------------------------------------
-- get_available_benefits — las casillas que el usuario puede tocar ahora
--
-- Las cinco condiciones, todas medidas contra el DÍA OPERATIVO (que empieza a las 06:00, no a
-- medianoche), nunca contra la fecha del calendario ni la hora del teléfono:
--
--   1. El beneficio está activo y su comercio está activo.
--   2. Hoy es uno de sus días de la semana.
--   3. Estamos dentro de su ventana horaria (que puede cruzar medianoche).
--   4. Le quedan cupos del día y de la semana.
--   5. Ese comercio no está en cooldown para este usuario.
--
-- Devuelve `condicion_consumo` en la misma fila que el título, siempre. La regla dura 4 dice que
-- nunca se muestra un beneficio sin su condición, y la forma de garantizarlo es que no exista una
-- consulta que devuelva lo uno sin lo otro.
-- ---------------------------------------------------------------------------

create function public.get_available_benefits()
returns table (
  benefit_id           uuid,
  merchant_id          uuid,
  merchant_nombre      text,
  rubro                public.rubro,
  logo_url             text,
  tipo                 public.benefit_tipo,
  titulo               text,
  condicion_consumo    text,
  descripcion          text,
  cupos_restantes_dia  integer
)
language sql
stable
security definer
set search_path = ''
as $$
  with estado as (
    select * from public.get_turn_state()
  ),
  ctx as (
    select
      (select auth.uid())            as user_id,
      now()                          as ahora,
      app.hora_local(now())          as hora,
      app.dia_operativo(now())       as dia,
      app.semana_operativa(now())    as lunes,
      extract(dow from app.dia_operativo(now()))::smallint as dow
  ),
  -- Los canjes que ocupan cupo, agrupados por beneficio. Se recorre redemptions una sola vez.
  ocupacion as (
    select
      r.benefit_id,
      count(*) filter (where r.dia_operativo = c.dia)                          as usados_dia,
      count(*) filter (where r.dia_operativo between c.lunes and c.lunes + 6)  as usados_semana
    from public.redemptions r, ctx c
    where r.dia_operativo between c.lunes and c.lunes + 6
      and app.redemption_ocupa(r.estado, r.expira_at)
    group by r.benefit_id
  ),
  -- Última validación del usuario en cada comercio. El cooldown corre desde `validado_at` y solo
  -- desde ahí (decisión 3): un canje abandonado, expirado o anulado no puede castigar al usuario.
  ultima_validacion as (
    select r.merchant_id, max(r.validado_at) as validado_at
    from public.redemptions r, ctx c
    where r.user_id = c.user_id
      and r.estado = 'validado'
      and r.validado_at is not null
    group by r.merchant_id
  )
  select
    b.id,
    m.id,
    m.nombre,
    m.rubro,
    m.logo_url,
    b.tipo,
    b.titulo,
    b.condicion_consumo,
    b.descripcion,
    case when br.cupos_dia is null then null
         else greatest(br.cupos_dia - coalesce(o.usados_dia, 0), 0)
    end::integer
  from public.benefits b
  join public.merchants m       on m.id = b.merchant_id
  join public.benefit_rules br  on br.benefit_id = b.id
  left join ocupacion o         on o.benefit_id = b.id
  left join ultima_validacion uv on uv.merchant_id = b.merchant_id
  cross join ctx c
  cross join estado e
  where e.motivo = 'disponible'
    and b.activo
    and m.activo
    and c.dow = any (br.dias_semana)
    and (
      br.hora_inicio is null or br.hora_fin is null
      or (br.hora_inicio <= br.hora_fin and c.hora >= br.hora_inicio and c.hora < br.hora_fin)
      or (br.hora_inicio >  br.hora_fin and (c.hora >= br.hora_inicio or c.hora < br.hora_fin))
    )
    and (br.cupos_dia    is null or coalesce(o.usados_dia, 0)    < br.cupos_dia)
    and (br.cupos_semana is null or coalesce(o.usados_semana, 0) < br.cupos_semana)
    and (
      uv.validado_at is null
      or uv.validado_at <= c.ahora - make_interval(days =>
           coalesce(m.cooldown_dias, app.setting_int('cooldown_dias_default'), 3))
    )
  order by m.nombre;
$$;

comment on function public.get_available_benefits() is
  'Las casillas que el usuario puede tocar ahora. Única fuente de verdad de la disponibilidad: cupos, cooldown, horarios y franjas se calculan acá y en ningún otro lugar. Devuelve vacío cuando get_turn_state() dice que no es turno del usuario, y el motivo se lee de esa función.';

grant execute on function
  public.get_turn_state(),
  public.get_available_benefits()
  to authenticated;
