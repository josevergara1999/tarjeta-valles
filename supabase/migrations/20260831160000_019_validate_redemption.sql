-- Migración 019 — `validate_redemption`
-- Hito 1 · T6. Referencias: spec 3.2 y 3.3, regla dura 3, decisión 12, seed-data escenarios 1, 8 y 9.
--
-- Acá se GASTA el giro. Es el momento que sostiene toda la regla antifraude: el usuario reserva
-- (T5) y el comercio confirma; si nadie confirma, el giro vuelve solo. Y por la decisión 12 es
-- también donde arranca el reloj de un pase sin estrenar.
--
-- Los rechazos van con `errcode = 'P0001'` y el motivo legible por máquina en DETAIL, igual que T5:
--
--   sin_sesion · sin_comercio · codigo_invalido · canje_inexistente · otro_comercio
--   canje_ya_usado · canje_expirado · canje_no_vigente · sin_saldo
--
-- Sobre `otro_comercio`: se distingue de `canje_inexistente` a propósito. Confirma que el código
-- existe, sí, pero quien pregunta es un comercio con sesión iniciada —no un anónimo probando— y la
-- diferencia le importa al cajero: "este código no es de acá" se resuelve mandando al cliente al
-- local correcto, mientras que "no existe" lo manda a pedir otro código. El mensaje NO dice de qué
-- comercio es.

-- ---------------------------------------------------------------------------
-- Cuánto dura cada pase
--
-- El spec 3.3 dice `fecha_expiracion = fecha_activacion + N días`, pero el N no estaba escrito en
-- ninguna parte: vivía solo en el nombre del producto y en la tabla de precios. Va a `settings`, como
-- todo parámetro de negocio (convención de CLAUDE.md): cambiar la duración de un pase es un update,
-- sin migración ni despliegue.
--
-- La clave se arma como `dias_` || tipo, así que agregar un pase nuevo en el Hito 2 es agregar su
-- fila acá y nada más.
--
-- Las suscripciones no están: arrancan al pagar, no al canjear. La decisión 12 es explícita en que la
-- activación diferida es solo para los pases.
-- ---------------------------------------------------------------------------

insert into public.settings (key, value, tipo, descripcion) values
  ('dias_pase_dia', '1',  'entero', 'Días que dura el Pase del Día desde que se activa con el primer canje validado.'),
  ('dias_pase_3',   '3',  'entero', 'Días que dura el pase de 3 días desde su activación.'),
  ('dias_pase_7',   '7',  'entero', 'Días que dura el pase de 7 días desde su activación.'),
  ('dias_pase_14',  '14', 'entero', 'Días que dura el pase de 14 días desde su activación.')
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- `validate_redemption`
-- ---------------------------------------------------------------------------

create or replace function public.validate_redemption(p_codigo text)
returns table (
  redemption_id     uuid,
  benefit_titulo    text,
  condicion_consumo text,
  cliente           text,
  validado_at       timestamptz
)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_user      uuid := (select auth.uid());
  v_ahora     timestamptz := now();
  v_merchant  uuid;
  v_operador  uuid;
  v_codigo    text := btrim(coalesce(p_codigo, ''));
  v_r         record;
  v_e         record;
  v_dias      integer;
begin
  if v_user is null then
    raise exception 'Hay que iniciar sesión'
      using errcode = 'P0001', detail = 'sin_sesion';
  end if;

  -- Quién valida. `validado_por` apunta a `merchant_users`, no a `auth.users`: interesa qué cuenta
  -- del local lo hizo, que es lo que después permite mirar el reporte por operador.
  select mu.merchant_id, mu.id into v_merchant, v_operador
  from public.merchant_users mu
  where mu.auth_user_id = v_user
    and mu.activo
  limit 1;

  if v_merchant is null then
    raise exception 'Esta cuenta no pertenece a ningún comercio activo'
      using errcode = 'P0001', detail = 'sin_comercio';
  end if;

  if v_codigo !~ '^[0-9]{6}$' then
    raise exception 'El código son 6 dígitos'
      using errcode = 'P0001', detail = 'codigo_invalido';
  end if;

  -- El canje más reciente con ese código. No se filtra por `estado = 'pendiente'` a propósito: si se
  -- filtrara, un código ya validado se respondería como inexistente y el cajero no sabría que el
  -- problema es que ya lo usaron. El índice único garantiza que a lo sumo UNO esté pendiente; los
  -- históricos pueden repetir código, por eso el `order by`.
  select r.id, r.user_id, r.entitlement_id, r.benefit_id, r.merchant_id,
         r.estado, r.expira_at
    into v_r
  from public.redemptions r
  where r.codigo = v_codigo
  order by r.created_at desc
  limit 1
  for update;

  if v_r.id is null then
    raise exception 'Ese código no existe'
      using errcode = 'P0001', detail = 'canje_inexistente';
  end if;

  -- ESCENARIO 9: Nevado no valida un código generado para Fogón.
  if v_r.merchant_id <> v_merchant then
    raise exception 'Ese código no es de este comercio'
      using errcode = 'P0001', detail = 'otro_comercio';
  end if;

  -- ESCENARIO 8: el mismo código no se valida dos veces.
  if v_r.estado = 'validado' then
    raise exception 'Ese código ya fue validado'
      using errcode = 'P0001', detail = 'canje_ya_usado';
  end if;

  if v_r.estado <> 'pendiente' then
    raise exception 'Ese canje ya no está vigente (está %)', v_r.estado
      using errcode = 'P0001', detail = 'canje_no_vigente';
  end if;

  -- ESCENARIO 2: si pasaron los minutos, el giro ya volvió al usuario.
  --
  -- Acá NO se marca el canje como expirado, aunque sea tentador. La primera versión lo hacía —un
  -- `update` y después el `raise`— y era código muerto: **al levantar una excepción, PL/pgSQL deshace
  -- todo lo que la función hizo antes**, incluido ese update. Rechazar y persistir algo en la misma
  -- llamada es imposible sin transacciones autónomas, que Postgres no tiene.
  --
  -- No hace falta igual: un pendiente vencido no ocupa cupo (`app.redemption_ocupa` lo excluye por
  -- fecha, sin importar la etiqueta) y el barrido de `create_redemption` lo marca la próxima vez que
  -- el usuario reserve. La etiqueta llega tarde pero nada depende de ella para funcionar.
  if v_r.expira_at <= v_ahora then
    raise exception 'Ese código ya venció; el cliente puede sacar otro'
      using errcode = 'P0001', detail = 'canje_expirado';
  end if;

  -- ---------------------------------------------------------------------------
  -- A partir de acá se compromete. Primero el giro, que es la regla dura 3.
  --
  -- El entitlement se toma con lock antes de tocarlo. El check `entitlements_saldo` de la 005 impide
  -- pasarse, pero llegar hasta ahí sería un error genuino: T5 eligió un entitlement con saldo y nadie
  -- más pudo gastarlo, porque un usuario tiene un solo canje pendiente a la vez.
  -- ---------------------------------------------------------------------------

  select e.id, e.tipo, e.estado, e.giros_usados, e.giros_totales
    into v_e
  from public.entitlements e
  where e.id = v_r.entitlement_id
  for update;

  if v_e.giros_usados >= v_e.giros_totales then
    raise exception 'El pase del cliente se quedó sin giros'
      using errcode = 'P0001', detail = 'sin_saldo';
  end if;

  update public.entitlements as e
     set giros_usados = e.giros_usados + 1
   where e.id = v_e.id;

  -- ---------------------------------------------------------------------------
  -- Y acá arranca el pase, si estaba sin estrenar (decisión 12).
  --
  -- NO se comprueba que el pase siga vigente. Es deliberado y está decidido: un turista que reservó a
  -- las 23:58 con el pase venciendo a medianoche y al que el mesón teclea el código a las 00:03 se
  -- valida igual. Hizo su parte a tiempo; rechazarlo sería castigarlo por la lentitud del local, y
  -- delante del cajero. El código vive 5 minutos, así que la ventana es mínima.
  -- ---------------------------------------------------------------------------

  if v_e.estado = 'pendiente_activacion' then
    if v_e.tipo::text like 'pase%' then
      v_dias := app.setting_int('dias_' || v_e.tipo::text);

      if v_dias is null then
        -- Preferible caerse que activar un pase sin fecha de vencimiento: eso sería un pase eterno,
        -- y nadie lo notaría hasta ver la factura de los comercios.
        raise exception 'Falta el parámetro dias_% en settings: no se puede activar el pase',
          v_e.tipo::text
          using errcode = 'P0001', detail = 'duracion_pase_sin_definir';
      end if;

      update public.entitlements as e
         set estado           = 'activo',
             fecha_activacion = v_ahora,
             fecha_expiracion = v_ahora + make_interval(days => v_dias)
       where e.id = v_e.id;
    else
      -- Bienvenida y cualquier otro que no sea pase: se activa sin vencimiento.
      update public.entitlements as e
         set estado           = 'activo',
             fecha_activacion = v_ahora
       where e.id = v_e.id;
    end if;
  end if;

  update public.redemptions as r
     set estado       = 'validado',
         validado_at  = v_ahora,
         validado_por = v_operador
   where r.id = v_r.id;

  -- Lo que el mesón necesita ver. El título y la condición de consumo van SIEMPRE juntos: es la regla
  -- dura 4, y acá importa más que en ningún lado, porque es el momento en que el mesero entrega.
  select b.titulo, b.condicion_consumo, u.nombre
    into benefit_titulo, condicion_consumo, cliente
  from public.benefits b
  join public.users u on u.id = v_r.user_id
  where b.id = v_r.benefit_id;

  redemption_id := v_r.id;
  validado_at   := v_ahora;
  return next;
end;
$$;

comment on function public.validate_redemption(text) is
  'El comercio valida un código de 6 dígitos: marca el canje, GASTA el giro (regla dura 3) y activa el pase si estaba sin estrenar (decisión 12). Solo valida códigos propios, vigentes y sin usar. Devuelve qué entregar y a quién.';

revoke all on function public.validate_redemption(text) from public, anon;
grant execute on function public.validate_redemption(text) to authenticated;

do $$
begin
  if has_function_privilege('anon', 'public.validate_redemption(text)', 'execute') then
    raise exception 'validate_redemption quedó abierta a anon.';
  end if;
  if not has_function_privilege('authenticated', 'public.validate_redemption(text)', 'execute') then
    raise exception 'authenticated no puede validar canjes.';
  end if;
  if (select count(*) from public.settings where key like 'dias_pase%') <> 4 then
    raise exception 'Faltan parámetros de duración de pases en settings.';
  end if;
end $$;
