-- Migración 018 — La ruleta también recibe las casillas apagadas, con su motivo
-- Hito 1 · amplía T4. Referencias: docs/seed-data.md escenarios 3, 4, 5 y 6.
--
-- EL PROBLEMA. `get_available_benefits()` devolvía solo lo tocable. Un comercio en cooldown, sin cupo
-- o fuera de horario no venía en la respuesta, así que la ruleta no tenía con qué dibujarlo. Pero
-- `seed-data.md` pide exactamente eso:
--
--   escenario 3: la casilla se ve apagada con "Agotado por hoy"
--   escenario 4: "un usuario que canjeó ayer en #2 ve esa casilla apagada con «Vuelve en 2 días»"
--   escenario 5: #1 no aparece disponible un sábado ni a las 20:00
--   escenario 6: un usuario con 0 giros VE la ruleta pero no puede reservar
--
-- Para eso hacen falta dos datos que no existían: qué comercios están apagados y por qué. Ahora la
-- función devuelve la red entera con `disponible`, `motivo` y `disponible_at`.
--
-- Se detectó ANTES de que José diseñara la ruleta, a propósito: si aparecía después, el diseño ya
-- estaría hecho suponiendo casillas apagadas que el backend no sabe entregar.

-- ---------------------------------------------------------------------------
-- Por qué el motivo es un enum y no un texto
--
-- El texto que ve el turista —"Vuelve en 2 días", "Agotado por hoy"— lo arma la pantalla, porque es
-- redacción y cambia con el diseño. Lo que viaja desde acá es la CAUSA, más `disponible_at` para que
-- la pantalla pueda decir "2 días" sin calcular nada por su cuenta. Si el cliente dedujera el
-- cooldown restando fechas, la regla estaría en dos lugares.
-- ---------------------------------------------------------------------------

create type public.benefit_motivo as enum (
  'disponible',
  'fuera_de_dia',          -- hoy no es uno de sus días
  'fuera_de_horario',      -- es su día, pero todavía no abre o ya cerró
  'cupo_dia_agotado',      -- se acabaron los cupos de hoy
  'cupo_semana_agotado',   -- se acabaron los de la semana
  'cooldown'               -- este usuario canjeó ahí hace poco
);

comment on type public.benefit_motivo is
  'Por qué una casilla de la ruleta está apagada. Es la CAUSA, no el texto: la redacción la pone la pantalla.';

-- ---------------------------------------------------------------------------
-- `app.proxima_apertura` — cuándo vuelve a abrir
--
-- Resuelve de una sola vez `fuera_de_dia` y `fuera_de_horario`, que son el mismo problema: buscar el
-- próximo instante en que la ventana del beneficio esté abierta.
--
-- Mira los próximos 8 días operativos, se queda con los que caen en `dias_semana` y devuelve la
-- primera apertura futura. Ocho y no siete para cubrir el caso de que la de hoy ya haya pasado.
--
-- Si el beneficio no tiene ventana horaria (`hora_inicio` nula, todo el día), abre cuando arranca el
-- día operativo — la misma hora que separa la madrugada del día anterior del día nuevo.
--
-- Trabaja sobre DÍAS OPERATIVOS, no sobre fechas de calendario, igual que el resto de la 008: para
-- una cervecería de 21:00 a 02:00, el canje de la 01:00 pertenece a la noche anterior y su `dow`
-- también.
-- ---------------------------------------------------------------------------

create or replace function app.proxima_apertura(
  p_dias        smallint[],
  p_hora_inicio time,
  p_desde       timestamptz
)
returns timestamptz
language sql
stable
set search_path = ''
as $$
  select min(c.apertura)
  from (
    select ((app.dia_operativo(p_desde) + d)
             + coalesce(p_hora_inicio,
                        app.setting_text('franja_manana_inicio')::time))
             at time zone app.zona_horaria()                              as apertura,
           extract(dow from (app.dia_operativo(p_desde) + d))::smallint   as dow
    from generate_series(0, 7) as d
  ) c
  where c.dow = any (p_dias)
    and c.apertura > p_desde;
$$;

comment on function app.proxima_apertura(smallint[], time, timestamptz) is
  'El próximo instante en que la ventana del beneficio vuelve a estar abierta, respetando días de la semana y hora de inicio. Razona en días operativos.';

-- ---------------------------------------------------------------------------
-- `get_available_benefits` — ahora devuelve la red entera
--
-- DOS CAMBIOS DE CONTRATO, los dos deliberados:
--
-- 1. Devuelve también lo NO disponible. Quien quiera solo lo tocable filtra `where disponible`.
--
-- 2. **Ya no depende del estado del turno.** Antes, si el usuario no tenía giros o había gastado su
--    franja, esta función devolvía vacío y la ruleta no se podía ni dibujar — lo que contradice el
--    escenario 6. Ahora `disponible` habla SOLO del comercio: si está abierto, con cupo y sin
--    cooldown. Que el usuario pueda girar o no lo sigue diciendo `get_turn_state()`.
--
--    La pantalla combina las dos cosas: casilla tocable = `get_turn_state().motivo = 'disponible'`
--    Y `disponible` de esta fila. Eso no es calcular una regla de negocio, es decidir qué pinta;
--    ninguna de las dos condiciones se deduce en el cliente, las dos llegan resueltas del backend.
--
-- QUÉ MOTIVO GANA cuando hay varios. El que libera ÚLTIMO. Si un local está cerrado ahora y además en
-- cooldown, decir "abre a las 19:00" sería mentir: a las 19:00 sigue bloqueado. Se elige el que de
-- verdad manda, que es siempre el de `disponible_at` más lejano.
-- ---------------------------------------------------------------------------

-- `create or replace` no sirve acá: Postgres no deja cambiar el tipo de retorno de una función
-- existente ("cannot change return type"), y estamos agregando tres columnas. Hay que soltarla.
--
-- Es seguro dentro de esta transacción: `create_redemption` la nombra pero plpgsql resuelve la
-- referencia al ejecutar, no al compilar, así que no hay dependencia que se rompa. Igual se la vuelve
-- a crear unas líneas más abajo y a `create_redemption` se la reescribe entera en esta misma
-- migración. Si algo fallara en el medio, la transacción deja todo como estaba.
drop function if exists public.get_available_benefits();

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
  cupos_restantes_dia  integer,
  disponible           boolean,
  motivo               public.benefit_motivo,
  disponible_at        timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  with ctx as (
    select
      (select auth.uid())                                 as user_id,
      now()                                               as ahora,
      app.hora_local(now())                               as hora,
      app.dia_operativo(now())                            as dia,
      app.semana_operativa(now())                         as lunes,
      extract(dow from app.dia_operativo(now()))::smallint as dow,
      app.setting_text('franja_manana_inicio')::time      as abre_dia,
      app.zona_horaria()                                  as tz
  ),
  ocupacion as (
    select
      r.benefit_id,
      count(*) filter (where r.dia_operativo = c.dia)                         as usados_dia,
      count(*) filter (where r.dia_operativo between c.lunes and c.lunes + 6) as usados_semana
    from public.redemptions r, ctx c
    where r.dia_operativo between c.lunes and c.lunes + 6
      and app.redemption_ocupa(r.estado, r.expira_at)
    group by r.benefit_id
  ),
  ultima_validacion as (
    select r.merchant_id, max(r.validado_at) as validado_at
    from public.redemptions r, ctx c
    where r.user_id = c.user_id
      and r.estado = 'validado'
      and r.validado_at is not null
    group by r.merchant_id
  ),
  base as (
    select
      b.id                as bid,
      m.id                as mid,
      m.nombre            as nombre,
      m.rubro             as rubro,
      m.logo_url          as logo_url,
      b.tipo              as tipo,
      b.titulo            as titulo,
      b.condicion_consumo as condicion_consumo,
      b.descripcion       as descripcion,
      br.cupos_dia        as cupos_dia,
      br.cupos_semana     as cupos_semana,
      br.dias_semana      as dias_semana,
      br.hora_inicio      as hora_inicio,
      br.hora_fin         as hora_fin,
      coalesce(o.usados_dia, 0)    as usados_dia,
      coalesce(o.usados_semana, 0) as usados_semana,
      uv.validado_at      as ultimo_canje,
      make_interval(days => coalesce(m.cooldown_dias,
                                     app.setting_int('cooldown_dias_default'),
                                     3)) as cooldown,
      c.ahora, c.hora, c.dia, c.lunes, c.dow, c.abre_dia, c.tz
    from public.benefits b
    join public.merchants m      on m.id = b.merchant_id
    join public.benefit_rules br on br.benefit_id = b.id
    left join ocupacion o          on o.benefit_id  = b.id
    left join ultima_validacion uv on uv.merchant_id = b.merchant_id
    cross join ctx c
    -- Un comercio apagado o un beneficio inactivo no son "no disponibles": no son parte de la red y
    -- no se dibujan. Apagado ≠ ausente.
    where b.activo and m.activo
  ),
  bloqueos as (
    select base.bid, x.motivo, x.libera_at
    from base
    cross join lateral (values
      (
        'cooldown'::public.benefit_motivo,
        case when base.ultimo_canje is not null
              and base.ultimo_canje > base.ahora - base.cooldown
             then base.ultimo_canje + base.cooldown
        end
      ),
      (
        'cupo_semana_agotado',
        case when base.cupos_semana is not null and base.usados_semana >= base.cupos_semana
             then ((base.lunes + 7) + base.abre_dia) at time zone base.tz
        end
      ),
      (
        'cupo_dia_agotado',
        case when base.cupos_dia is not null and base.usados_dia >= base.cupos_dia
             then ((base.dia + 1) + base.abre_dia) at time zone base.tz
        end
      ),
      (
        'fuera_de_dia',
        case when not (base.dow = any (base.dias_semana))
             then app.proxima_apertura(base.dias_semana, base.hora_inicio, base.ahora)
        end
      ),
      (
        'fuera_de_horario',
        case when base.dow = any (base.dias_semana)
              and base.hora_inicio is not null
              and base.hora_fin   is not null
              and not (
                    (base.hora_inicio <= base.hora_fin
                       and base.hora >= base.hora_inicio and base.hora < base.hora_fin)
                 or (base.hora_inicio >  base.hora_fin
                       and (base.hora >= base.hora_inicio or base.hora < base.hora_fin))
                  )
             then app.proxima_apertura(base.dias_semana, base.hora_inicio, base.ahora)
        end
      )
    ) as x(motivo, libera_at)
    where x.libera_at is not null
  ),
  manda as (
    -- El bloqueo que libera último es el que manda. Ver el comentario de arriba.
    select distinct on (bid) bid, motivo, libera_at
    from bloqueos
    order by bid, libera_at desc
  )
  select
    base.bid,
    base.mid,
    base.nombre,
    base.rubro,
    base.logo_url,
    base.tipo,
    base.titulo,
    base.condicion_consumo,
    base.descripcion,
    case when base.cupos_dia is null then null
         else greatest(base.cupos_dia - base.usados_dia, 0)
    end::integer,
    manda.bid is null,
    coalesce(manda.motivo, 'disponible'::public.benefit_motivo),
    manda.libera_at
  from base
  left join manda on manda.bid = base.bid
  -- Lo disponible primero: la ruleta puede dibujar en orden sin reordenar nada.
  order by (manda.bid is not null), base.nombre;
$$;

comment on function public.get_available_benefits() is
  'La red entera de casillas de la ruleta, disponibles y apagadas. `disponible` habla solo del comercio (horario, cupo, cooldown); si el USUARIO puede girar lo dice get_turn_state(). `motivo` es la causa del apagado y `disponible_at` cuándo vuelve, para que la pantalla escriba "Vuelve en 2 días" sin calcular nada. Única fuente de verdad de la disponibilidad.';

grant execute on function public.get_available_benefits() to authenticated;

-- `app.proxima_apertura` es interna: no se otorga a nadie. La llama esta función, que es SECURITY
-- DEFINER y por lo tanto resuelve permisos contra su dueño. Ver migraciones 015 y 016.
revoke all on function app.proxima_apertura(smallint[], time, timestamptz) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- `create_redemption` tiene que acotar a `disponible`
--
-- ESTO NO ES OPCIONAL, ES LA PARTE PELIGROSA DE ESTA MIGRACIÓN. La 013 revalida las 5 condiciones
-- preguntando si el beneficio sigue en la lista:
--
--     if not exists (select 1 from public.get_available_benefits() g
--                    where g.benefit_id = p_benefit_id) then ... rechazar
--
-- Con el contrato viejo eso alcanzaba, porque la lista traía SOLO lo disponible. Con el nuevo, la
-- lista trae también lo apagado, así que ese `exists` encontraría la fila de un local con el cupo
-- agotado y **dejaría reservar igual**. El agujero lo abre el cambio de contrato, no la 013.
--
-- Es el precio de que una función delegue su regla en otra: cuando la otra cambia lo que significa
-- "estar en la lista", la primera se rompe en silencio. Sigue valiendo la pena —una sola fuente de
-- verdad para los cupos— pero obliga a revisar a los consumidores cada vez que el contrato se mueve.
-- ---------------------------------------------------------------------------

create or replace function public.create_redemption(p_benefit_id uuid)
returns table (
  redemption_id uuid,
  codigo        text,
  expira_at     timestamptz,
  qr_payload    text
)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_user     uuid := (select auth.uid());
  v_ahora    timestamptz := now();
  v_merchant uuid;
  v_estado   record;
  v_ent      uuid;
  v_ttl      integer;
  v_expira   timestamptz;
  v_codigo   text;
  v_id       uuid;
  v_intento  integer;
begin
  if v_user is null then
    raise exception 'Hay que iniciar sesión para canjear'
      using errcode = 'P0001', detail = 'sin_sesion';
  end if;

  -- 1. Barrer los pendientes vencidos del usuario. Ver la 013: sin esto, quien dejó expirar un canje
  -- no vuelve a reservar nunca, porque el índice único bloquea también con un vencido sin marcar.
  update public.redemptions as r
     set estado = 'expirado'
   where r.user_id = v_user
     and r.estado = 'pendiente'
     and r.expira_at <= v_ahora;

  -- 2. Lock sobre el beneficio (decisión 1).
  select b.merchant_id into v_merchant
  from public.benefits b
  where b.id = p_benefit_id
  for update;

  if v_merchant is null then
    raise exception 'Ese beneficio no existe'
      using errcode = 'P0001', detail = 'beneficio_inexistente';
  end if;

  -- 3. Las dos puertas del usuario: saldo y ritmo.
  select * into v_estado from public.get_turn_state();

  if v_estado.motivo <> 'disponible' then
    raise exception 'No es turno de canjear: %', v_estado.motivo
      using errcode = 'P0001', detail = v_estado.motivo::text;
  end if;

  -- 4. Las 5 condiciones del beneficio, con el lock tomado. El `and g.disponible` es el cambio de la
  -- 018: la lista ahora incluye las casillas apagadas y sin ese filtro se reservaría sobre ellas.
  if not exists (
    select 1 from public.get_available_benefits() g
    where g.benefit_id = p_benefit_id
      and g.disponible
  ) then
    raise exception 'Ese beneficio ya no está disponible'
      using errcode = 'P0001', detail = 'beneficio_no_disponible';
  end if;

  -- 5. El giro que se gasta: el que expira antes, y los sin fecha al final.
  select e.id into v_ent
  from public.entitlements e
  where e.user_id = v_user
    and e.estado in ('activo', 'pendiente_activacion')
    and (e.fecha_expiracion is null or e.fecha_expiracion > v_ahora)
    and e.giros_usados < e.giros_totales
  order by e.fecha_expiracion asc nulls last, e.created_at asc
  limit 1;

  if v_ent is null then
    raise exception 'No hay ningún giro disponible para gastar'
      using errcode = 'P0001', detail = 'sin_entitlement';
  end if;

  -- No se activa el pase acá: la decisión 12 lo pone en la validación.

  v_ttl    := coalesce(app.setting_int('ttl_codigo_canje_minutos'), 5);
  v_expira := v_ahora + make_interval(mins => v_ttl);

  for v_intento in 1..10 loop
    begin
      v_codigo := app.codigo_canje();

      insert into public.redemptions
        (user_id, entitlement_id, benefit_id, merchant_id, codigo, estado,
         created_at, expira_at, franja, dia_operativo)
      values
        (v_user, v_ent, p_benefit_id, v_merchant, v_codigo, 'pendiente',
         v_ahora, v_expira, app.franja_en(v_ahora), app.dia_operativo(v_ahora))
      returning id into v_id;

      exit;
    exception when unique_violation then
      if position('un_pendiente_por_usuario' in coalesce(sqlerrm, '')) > 0 then
        raise exception 'Ya tenés un canje abierto'
          using errcode = 'P0001', detail = 'canje_pendiente';
      end if;
      v_id := null;
    end;
  end loop;

  if v_id is null then
    raise exception 'No se pudo generar un código libre'
      using errcode = 'P0001', detail = 'codigo_no_generado';
  end if;

  redemption_id := v_id;
  codigo        := v_codigo;
  expira_at     := v_expira;
  qr_payload    := app.firmar_canje(v_id, v_merchant, v_expira);
  return next;
end;
$$;

do $$
begin
  if has_function_privilege('authenticated', 'app.proxima_apertura(smallint[], time, timestamptz)', 'execute')
     or has_function_privilege('anon', 'app.proxima_apertura(smallint[], time, timestamptz)', 'execute') then
    raise exception 'app.proxima_apertura quedó ejecutable desde la API.';
  end if;

  if not has_function_privilege('authenticated', 'public.get_available_benefits()', 'execute') then
    raise exception 'authenticated perdió acceso a get_available_benefits.';
  end if;
end $$;
