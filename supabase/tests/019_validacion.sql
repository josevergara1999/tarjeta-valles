-- Pruebas de la migración 019 — validate_redemption
--
-- Cómo se corre: pegar entero en el SQL Editor de Supabase (o `psql -f`). Crea sus propios datos,
-- comprueba y hace ROLLBACK: no deja nada en la base y se puede repetir las veces que haga falta.
--
-- El SQL Editor no muestra `raise notice`, así que todo lo que falla lo hace con `raise exception`.
-- Si termina diciendo `Success. No rows returned`, pasaron todas.
--
-- Acá se cierra el circuito completo: reservar (T5) → validar (T6). Es el escenario 1 de
-- seed-data.md de punta a punta, más el 8 y el 9, que son antifraude puro.

begin;

-- Ver el comentario equivalente en 013_canje.sql: las pruebas calculan valores esperados con las
-- funciones internas de `app`, cerradas desde la 015. El rollback deshace estos permisos.
grant usage on schema app to authenticated;
grant execute on all functions in schema app to authenticated;

-- El código del canje tiene que viajar entre bloques que corren con roles distintos: lo genera el
-- turista y lo teclea el comercio. Va en una tabla temporal, que muere con el rollback.
--
-- El primer intento usó `public.settings` como lugar de paso y RLS lo rechazó, con razón: un usuario
-- que no es admin no escribe parámetros del negocio. La prueba estaba pidiendo algo que el sistema
-- debe negar.
create temp table t_cod (codigo text) on commit drop;
grant all on table t_cod to authenticated;

-- ---------------------------------------------------------------------------
-- Datos: dos comercios con su dueño, y un turista con un pase SIN ESTRENAR
--
-- El pase sin estrenar es lo que permite comprobar la decisión 12: tiene que despertar recién cuando
-- el local valida, no cuando el turista reserva.
-- ---------------------------------------------------------------------------

insert into auth.users (id, instance_id, aud, role, phone, phone_confirmed_at, created_at, updated_at)
values ('7e6a0000-0000-4000-a000-000000000001', '00000000-0000-0000-0000-000000000000',
        'authenticated', 'authenticated', '+56900000301', now(), now(), now());

insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
values
  ('7e6a0000-0000-4000-a000-000000000011', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'dueno@uno.test', 'x', now(), now(), now()),
  ('7e6a0000-0000-4000-a000-000000000012', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'dueno@dos.test', 'x', now(), now(), now());

insert into public.users (id, telefono, nombre)
values ('7e6a0000-0000-4000-a000-000000000001', '+56900000301', 'Turista T6');

insert into public.merchants (id, nombre, rubro, activo, cooldown_dias) values
  ('7e6a1111-0000-4000-a000-000000000001', 'Local T6 uno', 'restaurante', true, 3),
  ('7e6a1111-0000-4000-a000-000000000002', 'Local T6 dos', 'cerveceria',  true, 3);

insert into public.merchant_users (id, merchant_id, auth_user_id, email, rol) values
  ('7e6a5555-0000-4000-a000-000000000001', '7e6a1111-0000-4000-a000-000000000001',
   '7e6a0000-0000-4000-a000-000000000011', 'dueno@uno.test', 'dueno'),
  ('7e6a5555-0000-4000-a000-000000000002', '7e6a1111-0000-4000-a000-000000000002',
   '7e6a0000-0000-4000-a000-000000000012', 'dueno@dos.test', 'dueno');

insert into public.benefits (id, merchant_id, tipo, titulo, condicion_consumo, activo) values
  ('7e6a2222-0000-4000-a000-000000000001', '7e6a1111-0000-4000-a000-000000000001',
   'cortesia', 'Postre de cortesía', 'con plato principal', true),
  ('7e6a2222-0000-4000-a000-000000000002', '7e6a1111-0000-4000-a000-000000000002',
   'cortesia', 'Schop de cortesía',  'con la segunda ronda', true);

update public.benefit_rules
set cupos_dia = 10, cupos_semana = 50, dias_semana = '{0,1,2,3,4,5,6}',
    hora_inicio = null, hora_fin = null
where benefit_id in ('7e6a2222-0000-4000-a000-000000000001',
                     '7e6a2222-0000-4000-a000-000000000002');

-- Pase de 3 días recién comprado: pendiente_activacion, sin fechas.
insert into public.entitlements
  (id, user_id, tipo, giros_totales, giros_usados, estado)
values ('7e6a3333-0000-4000-a000-000000000001', '7e6a0000-0000-4000-a000-000000000001',
        'pase_3', 9, 0, 'pendiente_activacion');

-- ---------------------------------------------------------------------------
-- 1. ESCENARIO 1 completo: reserva → validación → giro descontado
-- ---------------------------------------------------------------------------

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"7e6a0000-0000-4000-a000-000000000001","role":"authenticated"}';

do $$
declare r record;
begin
  select * into r from public.create_redemption('7e6a2222-0000-4000-a000-000000000001');
  insert into t_cod values (r.codigo);
end $$;

-- Antes de validar: el giro NO se gastó y el pase NO despertó (regla dura 3 + decisión 12).
reset role;

do $$
declare v_usados int; v_estado public.entitlement_estado;
begin
  select giros_usados, estado into v_usados, v_estado
  from public.entitlements where id = '7e6a3333-0000-4000-a000-000000000001';

  if v_usados <> 0 then
    raise exception 'FALLA: reservar gastó % giros; se gastan al VALIDAR', v_usados;
  end if;

  if v_estado <> 'pendiente_activacion' then
    raise exception 'FALLA: reservar activó el pase (quedó %)', v_estado;
  end if;
end $$;

-- Ahora valida el comercio dueño del código.
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"7e6a0000-0000-4000-a000-000000000011","role":"authenticated"}';

do $$
declare
  v_cod text;
  r     record;
begin
  select codigo into v_cod from t_cod;

  select * into r from public.validate_redemption(v_cod);

  if r.redemption_id is null then
    raise exception 'FALLA: la validación no devolvió el canje';
  end if;

  -- Regla dura 4: el mesón tiene que ver qué entrega Y bajo qué condición.
  if r.benefit_titulo <> 'Postre de cortesía' then
    raise exception 'FALLA: devolvió el beneficio "%"', r.benefit_titulo;
  end if;

  if r.condicion_consumo <> 'con plato principal' then
    raise exception 'FALLA: la condición de consumo no viajó (llegó "%")', r.condicion_consumo;
  end if;

  if r.cliente <> 'Turista T6' then
    raise exception 'FALLA: no devolvió el nombre del cliente (llegó "%")', r.cliente;
  end if;
end $$;

reset role;

do $$
declare
  v_r      record;
  v_e      record;
begin
  select estado, validado_at, validado_por into v_r
  from public.redemptions
  where user_id = '7e6a0000-0000-4000-a000-000000000001'
  order by created_at desc limit 1;

  if v_r.estado <> 'validado' then
    raise exception 'FALLA: el canje quedó en %, debería estar validado', v_r.estado;
  end if;

  if v_r.validado_at is null then
    raise exception 'FALLA: validado sin hora';
  end if;

  -- Queda registrado QUÉ CUENTA del local validó, no solo el local.
  if v_r.validado_por <> '7e6a5555-0000-4000-a000-000000000001' then
    raise exception 'FALLA: validado_por es %, debería ser el operador que validó', v_r.validado_por;
  end if;

  select giros_usados, estado, fecha_activacion, fecha_expiracion into v_e
  from public.entitlements where id = '7e6a3333-0000-4000-a000-000000000001';

  -- REGLA DURA 3: el giro se gasta acá y no antes.
  if v_e.giros_usados <> 1 then
    raise exception 'FALLA: giros_usados quedó en %, debería ser 1', v_e.giros_usados;
  end if;

  -- DECISIÓN 12: el pase arranca con la validación.
  if v_e.estado <> 'activo' then
    raise exception 'FALLA: el pase quedó en %, debería haberse activado', v_e.estado;
  end if;

  if v_e.fecha_activacion is null then
    raise exception 'FALLA: el pase se activó sin fecha de activación';
  end if;

  -- Y dura lo que dice settings, no un número escrito a mano.
  if v_e.fecha_expiracion is null then
    raise exception 'FALLA: el pase se activó SIN VENCIMIENTO; sería un pase eterno';
  end if;

  if abs(extract(epoch from (v_e.fecha_expiracion
        - (v_e.fecha_activacion + make_interval(days => app.setting_int('dias_pase_3')))))) > 60 then
    raise exception 'FALLA: el vencimiento no respeta dias_pase_3 (= %)', app.setting_int('dias_pase_3');
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 2. ESCENARIO 8: el mismo código no se valida dos veces
-- ---------------------------------------------------------------------------

set local role authenticated;

do $$
declare v_cod text; v_detalle text; v_ok boolean := false;
begin
  set local request.jwt.claims =
    '{"sub":"7e6a0000-0000-4000-a000-000000000011","role":"authenticated"}';
  select codigo into v_cod from t_cod;

  begin
    perform * from public.validate_redemption(v_cod);
  exception when sqlstate 'P0001' then
    get stacked diagnostics v_detalle = pg_exception_detail;
    v_ok := (v_detalle = 'canje_ya_usado');
  end;

  if not v_ok then
    raise exception 'FALLA: validó dos veces el mismo código (detalle: %)',
      coalesce(v_detalle, 'ninguno, no rechazó');
  end if;
end $$;

-- Y el giro no se gastó dos veces.
reset role;

do $$
declare v_usados int;
begin
  select giros_usados into v_usados
  from public.entitlements where id = '7e6a3333-0000-4000-a000-000000000001';
  if v_usados <> 1 then
    raise exception 'FALLA: giros_usados quedó en % tras el rechazo; debería seguir en 1', v_usados;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 3. ESCENARIO 9: un comercio no valida el código de otro
--
-- Es el que impide que un local se apropie de los canjes de la competencia.
-- ---------------------------------------------------------------------------

-- Nuevo canje del turista, otra vez en el local UNO. Para que pueda hay que mover el canje anterior
-- entero al pasado, no solo `validado_at`: si se mueve la validación pero se deja `dia_operativo` y
-- `franja` en hoy, el cooldown se libera pero la FRANJA sigue gastada y `create_redemption` rechaza
-- con `franja_gastada`. Son dos bloqueos distintos que se apoyan en columnas distintas.
update public.redemptions
set created_at    = now() - interval '30 days',
    expira_at     = now() - interval '30 days' + interval '5 minutes',
    validado_at   = now() - interval '30 days' + interval '1 minute',
    dia_operativo = app.dia_operativo(now() - interval '30 days'),
    franja        = app.franja_en(now() - interval '30 days')
where user_id = '7e6a0000-0000-4000-a000-000000000001' and estado = 'validado';

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"7e6a0000-0000-4000-a000-000000000001","role":"authenticated"}';

do $$
declare r record;
begin
  select * into r from public.create_redemption('7e6a2222-0000-4000-a000-000000000001');
  update t_cod set codigo = r.codigo;
end $$;

do $$
declare v_cod text; v_detalle text; v_ok boolean := false;
begin
  -- Ahora entra el dueño del local DOS con el código del local UNO.
  set local request.jwt.claims =
    '{"sub":"7e6a0000-0000-4000-a000-000000000012","role":"authenticated"}';
  select codigo into v_cod from t_cod;

  begin
    perform * from public.validate_redemption(v_cod);
  exception when sqlstate 'P0001' then
    get stacked diagnostics v_detalle = pg_exception_detail;
    v_ok := (v_detalle = 'otro_comercio');
  end;

  if not v_ok then
    raise exception 'FALLA: un comercio validó el código de otro (detalle: %)',
      coalesce(v_detalle, 'ninguno, no rechazó');
  end if;
end $$;

-- El canje sigue intacto, esperando a su comercio.
reset role;

do $$
declare v_estado public.redemption_estado; v_usados int;
begin
  select estado into v_estado from public.redemptions
  where user_id = '7e6a0000-0000-4000-a000-000000000001' and estado = 'pendiente';
  if v_estado is null then
    raise exception 'FALLA: el intento del comercio ajeno tocó el canje';
  end if;

  select giros_usados into v_usados
  from public.entitlements where id = '7e6a3333-0000-4000-a000-000000000001';
  if v_usados <> 1 then
    raise exception 'FALLA: el intento ajeno gastó un giro (giros_usados = %)', v_usados;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 4. ESCENARIO 2 desde el mesón: un código vencido se rechaza y queda marcado
-- ---------------------------------------------------------------------------

update public.redemptions
set created_at = now() - interval '20 minutes',
    expira_at  = now() - interval '15 minutes'
where user_id = '7e6a0000-0000-4000-a000-000000000001' and estado = 'pendiente';

set local role authenticated;

do $$
declare v_cod text; v_detalle text; v_ok boolean := false;
begin
  set local request.jwt.claims =
    '{"sub":"7e6a0000-0000-4000-a000-000000000011","role":"authenticated"}';
  select codigo into v_cod from t_cod;

  begin
    perform * from public.validate_redemption(v_cod);
  exception when sqlstate 'P0001' then
    get stacked diagnostics v_detalle = pg_exception_detail;
    v_ok := (v_detalle = 'canje_expirado');
  end;

  if not v_ok then
    raise exception 'FALLA: validó un código vencido (detalle: %)',
      coalesce(v_detalle, 'ninguno, no rechazó');
  end if;
end $$;

reset role;

do $$
declare v_r record;
begin
  -- El rechazo NO cambia la etiqueta, y está bien que no lo haga: al levantar la excepción, PL/pgSQL
  -- deshace todo lo que la función hizo. Lo que importa es que un vencido no ocupe nada mientras
  -- tanto — la etiqueta la pone el barrido de T5 en la próxima reserva.
  select estado, expira_at into v_r
  from public.redemptions
  where user_id = '7e6a0000-0000-4000-a000-000000000001'
  order by created_at desc limit 1;

  if v_r.expira_at > now() then
    raise exception 'FALLA: el canje de la prueba no quedó vencido';
  end if;

  if app.redemption_ocupa(v_r.estado, v_r.expira_at) then
    raise exception 'FALLA: un pendiente vencido sigue ocupando cupo (estado %)', v_r.estado;
  end if;
end $$;

-- Y el barrido de T5 sí lo etiqueta: el usuario reserva de nuevo y el fantasma queda cerrado.
set local role authenticated;

do $$
declare r record; v_n int;
begin
  set local request.jwt.claims =
    '{"sub":"7e6a0000-0000-4000-a000-000000000001","role":"authenticated"}';
  select * into r from public.create_redemption('7e6a2222-0000-4000-a000-000000000002');
  perform public.cancel_redemption(r.redemption_id);
end $$;

reset role;

do $$
declare v_n int;
begin
  select count(*) into v_n from public.redemptions
  where user_id = '7e6a0000-0000-4000-a000-000000000001' and estado = 'expirado';
  if v_n <> 1 then
    raise exception 'FALLA: el barrido de T5 no etiquetó el vencido (hay % expirados)', v_n;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 5. Códigos que no existen, mal formados, y cuentas que no son de ningún comercio
-- ---------------------------------------------------------------------------

set local role authenticated;

do $$
declare v_detalle text; v_ok boolean := false;
begin
  set local request.jwt.claims =
    '{"sub":"7e6a0000-0000-4000-a000-000000000011","role":"authenticated"}';
  begin
    perform * from public.validate_redemption('000000');
  exception when sqlstate 'P0001' then
    get stacked diagnostics v_detalle = pg_exception_detail;
    v_ok := (v_detalle = 'canje_inexistente');
  end;
  if not v_ok then
    raise exception 'FALLA: aceptó un código inexistente (detalle: %)',
      coalesce(v_detalle, 'ninguno, no rechazó');
  end if;
end $$;

do $$
declare v_detalle text; v_ok boolean := false;
begin
  set local request.jwt.claims =
    '{"sub":"7e6a0000-0000-4000-a000-000000000011","role":"authenticated"}';
  begin
    perform * from public.validate_redemption('12ab');
  exception when sqlstate 'P0001' then
    get stacked diagnostics v_detalle = pg_exception_detail;
    v_ok := (v_detalle = 'codigo_invalido');
  end;
  if not v_ok then
    raise exception 'FALLA: aceptó un código mal formado (detalle: %)',
      coalesce(v_detalle, 'ninguno, no rechazó');
  end if;
end $$;

do $$
declare v_detalle text; v_ok boolean := false;
begin
  -- El turista intentando validarse a sí mismo: no pertenece a ningún comercio.
  set local request.jwt.claims =
    '{"sub":"7e6a0000-0000-4000-a000-000000000001","role":"authenticated"}';
  begin
    perform * from public.validate_redemption('123456');
  exception when sqlstate 'P0001' then
    get stacked diagnostics v_detalle = pg_exception_detail;
    v_ok := (v_detalle = 'sin_comercio');
  end;
  if not v_ok then
    raise exception 'FALLA: un usuario final pudo entrar a validar (detalle: %)',
      coalesce(v_detalle, 'ninguno, no rechazó');
  end if;
end $$;

reset role;

rollback;
