-- Pruebas de las migraciones 012 y 013 — create_redemption y cancel_redemption
--
-- Cómo se corre: pegar entero en el SQL Editor de Supabase (o `psql -f`). Crea sus propios datos,
-- comprueba y hace ROLLBACK: no deja nada en la base y se puede repetir las veces que haga falta.
--
-- El SQL Editor no muestra `raise notice`, así que todo lo que falla lo hace con `raise exception`.
-- Si termina diciendo `Success. No rows returned`, pasaron todas.
--
-- Patrón que se repite: para comprobar que algo se RECHAZA no se puede envolver el `raise exception`
-- del fallo dentro del mismo `exception when` que atrapa el rechazo, porque los dos usan P0001 y el
-- handler se comería la comprobación. Se guarda el veredicto en una variable y se levanta después.

begin;

-- Las pruebas calculan sus valores esperados con las funciones internas de `app` (`franja_en`,
-- `dia_operativo`, `setting_int`...), y desde la migración 015 ese esquema está cerrado a los roles de
-- la API. Se conceden acá los permisos, DENTRO de la transacción: el `rollback` del final los deshace,
-- así que la base vuelve a quedar cerrada y esto no relaja nada fuera de la prueba.
--
-- No debilita lo que se está comprobando: `app.*` se usa para saber qué franja es o qué día operativo
-- corre, nunca para probar control de acceso. Lo que sí prueba accesos —RLS, quién puede llamar a
-- create_redemption— no toca `app` en ningún momento.
grant usage on schema app to authenticated;
grant execute on all functions in schema app to authenticated;

-- ---------------------------------------------------------------------------
-- Datos de la prueba
--
-- Ids con prefijo `7e5c…` (test canje) para no depender de la semilla ni ensuciar sus conteos.
-- ---------------------------------------------------------------------------

insert into auth.users (id, instance_id, aud, role, phone, phone_confirmed_at, created_at, updated_at)
values
  ('7e5c0000-0000-4000-a000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', '+56900000101', now(), now(), now()),
  ('7e5c0000-0000-4000-a000-000000000002', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', '+56900000102', now(), now(), now()),
  ('7e5c0000-0000-4000-a000-000000000003', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', '+56900000103', now(), now(), now());

insert into public.users (id, telefono, nombre) values
  ('7e5c0000-0000-4000-a000-000000000001', '+56900000101', 'Canjeador'),
  ('7e5c0000-0000-4000-a000-000000000002', '+56900000102', 'Vecino'),
  ('7e5c0000-0000-4000-a000-000000000003', '+56900000103', 'Sin giros');

insert into public.merchants (id, nombre, rubro, activo, cooldown_dias) values
  ('7e5c1111-0000-4000-a000-000000000001', 'Local T5 uno', 'restaurante', true, 3),
  ('7e5c1111-0000-4000-a000-000000000002', 'Local T5 dos', 'cerveceria', true, 3);

insert into public.benefits (id, merchant_id, tipo, titulo, condicion_consumo, activo) values
  ('7e5c2222-0000-4000-a000-000000000001', '7e5c1111-0000-4000-a000-000000000001',
   'descuento', 'Beneficio uno', 'Con la segunda ronda', true),
  ('7e5c2222-0000-4000-a000-000000000002', '7e5c1111-0000-4000-a000-000000000002',
   'descuento', 'Beneficio dos', 'Sin condiciones', true);

-- Sin ventana horaria ni límite de días: lo que se prueba acá es la reserva, no las condiciones,
-- que ya tienen sus 38 comprobaciones en 008_franjas.sql.
update public.benefit_rules
set cupos_dia = 2, cupos_semana = 10, dias_semana = '{0,1,2,3,4,5,6}',
    hora_inicio = null, hora_fin = null
where benefit_id in ('7e5c2222-0000-4000-a000-000000000001',
                     '7e5c2222-0000-4000-a000-000000000002');

-- El canjeador tiene DOS entitlements vivos, para probar cuál se gasta primero. El que vence el
-- lunes tiene que gastarse antes que el que no vence nunca.
insert into public.entitlements
  (id, user_id, tipo, giros_totales, giros_usados, estado, fecha_activacion, fecha_expiracion)
values
  ('7e5c3333-0000-4000-a000-000000000011', '7e5c0000-0000-4000-a000-000000000001',
   'pase_3', 9, 0, 'activo', now(), now() + interval '2 days'),
  ('7e5c3333-0000-4000-a000-000000000012', '7e5c0000-0000-4000-a000-000000000001',
   'suscripcion_mensual', 8, 0, 'activo', now(), null);

insert into public.entitlements
  (id, user_id, tipo, giros_totales, giros_usados, estado, fecha_activacion)
values ('7e5c3333-0000-4000-a000-000000000021', '7e5c0000-0000-4000-a000-000000000002',
        'pase_3', 9, 0, 'activo', now());

-- El tercero no tiene entitlements: es el caso "sin giros".

-- ---------------------------------------------------------------------------
-- 1. La reserva feliz
--
-- Lo que tiene que quedar: un pendiente, código de 6 dígitos, vencimiento según settings, y la
-- franja y el día operativo escritos — sin ellos el conteo de cupos de T4 no sabe a qué día sumar.
-- ---------------------------------------------------------------------------

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"7e5c0000-0000-4000-a000-000000000001","role":"authenticated"}';

do $$
declare
  r        record;
  v_ttl    integer := coalesce(app.setting_int('ttl_codigo_canje_minutos'), 5);
  v_estado public.redemption_estado;
  v_franja public.franja_dia;
  v_dia    date;
  v_ent    uuid;
begin
  select * into r from public.create_redemption('7e5c2222-0000-4000-a000-000000000001');

  if r.redemption_id is null then
    raise exception 'FALLA: la reserva no devolvió id';
  end if;

  if r.codigo !~ '^[0-9]{6}$' then
    raise exception 'FALLA: el código "%" no son 6 dígitos', r.codigo;
  end if;

  -- Un minuto de tolerancia: lo que importa es que salga de settings y no de un número escrito a mano.
  if abs(extract(epoch from (r.expira_at - (now() + make_interval(mins => v_ttl))))) > 60 then
    raise exception 'FALLA: expira_at no respeta ttl_codigo_canje_minutos (=%)', v_ttl;
  end if;

  select estado, franja, dia_operativo, entitlement_id
    into v_estado, v_franja, v_dia, v_ent
  from public.redemptions where id = r.redemption_id;

  if v_estado <> 'pendiente' then
    raise exception 'FALLA: la reserva nació en estado %, debería ser pendiente', v_estado;
  end if;

  if v_franja is null or v_dia is null then
    raise exception 'FALLA: la reserva no escribió franja/dia_operativo (% / %)', v_franja, v_dia;
  end if;

  if v_franja <> app.franja_en(now()) or v_dia <> app.dia_operativo(now()) then
    raise exception 'FALLA: franja o día operativo no coinciden con el reloj';
  end if;

  -- Decisión de los menores: se gasta el que expira antes. El pase vence en 2 días, la suscripción
  -- no vence nunca, así que tiene que haber elegido el pase.
  if v_ent <> '7e5c3333-0000-4000-a000-000000000011' then
    raise exception 'FALLA: gastó el entitlement %, debía gastar el que expira antes', v_ent;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 2. Reservar NO descuenta el giro ni activa el pase
--
-- Es la regla dura 3 y la decisión 12, las dos en la misma comprobación. `giros_usados` sube al
-- validar, no al reservar; y el pase arranca cuando el local valida, no cuando el usuario elige.
-- Si esto se rompe, un turista que abre la ruleta en el bus y se arrepiente pierde un giro y un día.
-- ---------------------------------------------------------------------------

reset role;

do $$
declare n int;
begin
  select sum(giros_usados) into n from public.entitlements
  where user_id = '7e5c0000-0000-4000-a000-000000000001';
  if n <> 0 then
    raise exception 'FALLA: reservar descontó % giros; el giro se descuenta al VALIDAR', n;
  end if;
end $$;

-- Un pase sin estrenar, para comprobar que la reserva no lo despierta.
insert into public.entitlements
  (id, user_id, tipo, giros_totales, giros_usados, estado)
values ('7e5c3333-0000-4000-a000-000000000031', '7e5c0000-0000-4000-a000-000000000003',
        'pase_3', 9, 0, 'pendiente_activacion');

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"7e5c0000-0000-4000-a000-000000000003","role":"authenticated"}';

do $$
declare v_est public.entitlement_estado; r record;
begin
  select * into r from public.create_redemption('7e5c2222-0000-4000-a000-000000000001');

  select estado into v_est from public.entitlements
  where id = '7e5c3333-0000-4000-a000-000000000031';

  if v_est <> 'pendiente_activacion' then
    raise exception 'FALLA: reservar activó el pase (quedó %); la decisión 12 lo pone en la validación', v_est;
  end if;

  perform public.cancel_redemption(r.redemption_id);
end $$;

-- ---------------------------------------------------------------------------
-- 3. Un solo canje pendiente por usuario (decisión 2)
-- ---------------------------------------------------------------------------

reset role;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"7e5c0000-0000-4000-a000-000000000001","role":"authenticated"}';

do $$
declare v_detalle text; v_ok boolean := false;
begin
  begin
    perform * from public.create_redemption('7e5c2222-0000-4000-a000-000000000002');
  exception when sqlstate 'P0001' then
    get stacked diagnostics v_detalle = pg_exception_detail;
    v_ok := (v_detalle = 'canje_pendiente');
  end;

  if not v_ok then
    raise exception 'FALLA: dejó abrir un segundo canje teniendo uno vigente (detalle: %)',
      coalesce(v_detalle, 'ninguno, no rechazó');
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Cancelar libera al instante y deja rastro distinto de "expirado"
-- ---------------------------------------------------------------------------

do $$
declare
  v_id  uuid;
  v_est public.redemption_estado;
  r     record;
begin
  select id into v_id from public.redemptions
  where user_id = '7e5c0000-0000-4000-a000-000000000001' and estado = 'pendiente';

  perform public.cancel_redemption(v_id);

  select estado into v_est from public.redemptions where id = v_id;
  if v_est <> 'cancelado' then
    raise exception 'FALLA: el canje cancelado quedó en %, debería quedar en cancelado', v_est;
  end if;

  -- Y el giro volvió: puede reservar de nuevo en el acto. Si esto fallara, ofrecerle al usuario
  -- cancelar el canje anterior no serviría de nada, que es justo lo que promete la decisión 2.
  select * into r from public.create_redemption('7e5c2222-0000-4000-a000-000000000002');
  if r.redemption_id is null then
    raise exception 'FALLA: después de cancelar no pudo volver a reservar';
  end if;

  perform public.cancel_redemption(r.redemption_id);
end $$;

-- ---------------------------------------------------------------------------
-- 5. Cancelar lo ajeno y cancelar lo que ya no está pendiente
--
-- El canje de otro se responde igual que uno inexistente, a propósito: distinguirlos permitiría
-- averiguar qué ids existen probando.
-- ---------------------------------------------------------------------------

do $$
declare
  v_ajeno   uuid;
  v_detalle text;
  v_ok      boolean := false;
begin
  -- Un canje del vecino, creado con su propia sesión.
  set local request.jwt.claims =
    '{"sub":"7e5c0000-0000-4000-a000-000000000002","role":"authenticated"}';
  select redemption_id into v_ajeno
  from public.create_redemption('7e5c2222-0000-4000-a000-000000000001');

  set local request.jwt.claims =
    '{"sub":"7e5c0000-0000-4000-a000-000000000001","role":"authenticated"}';
  begin
    perform public.cancel_redemption(v_ajeno);
  exception when sqlstate 'P0001' then
    get stacked diagnostics v_detalle = pg_exception_detail;
    v_ok := (v_detalle = 'canje_inexistente');
  end;

  if not v_ok then
    raise exception 'FALLA: pudo cancelar el canje de otro usuario (detalle: %)',
      coalesce(v_detalle, 'ninguno, no rechazó');
  end if;
end $$;

do $$
declare
  v_id      uuid;
  v_detalle text;
  v_ok      boolean := false;
  r         record;
begin
  set local request.jwt.claims =
    '{"sub":"7e5c0000-0000-4000-a000-000000000001","role":"authenticated"}';
  select * into r from public.create_redemption('7e5c2222-0000-4000-a000-000000000002');

  -- La primera cancelación es legítima y tiene que pasar sin ruido.
  perform public.cancel_redemption(r.redemption_id);

  -- La segunda es la que se está probando.
  begin
    perform public.cancel_redemption(r.redemption_id);
  exception when sqlstate 'P0001' then
    get stacked diagnostics v_detalle = pg_exception_detail;
    v_ok := (v_detalle = 'canje_no_pendiente');
  end;

  if not v_ok then
    raise exception 'FALLA: dejó cancelar dos veces el mismo canje (detalle: %)',
      coalesce(v_detalle, 'ninguno, no rechazó');
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 6. EL BARRIDO. Un pendiente vencido sin marcar no puede dejar al usuario encerrado.
--
-- `redemptions_un_pendiente_por_usuario` es más estricto que la decisión 2: bloquea con cualquier
-- fila en 'pendiente', también una que venció hace horas. Sin el barrido del paso 1 de
-- create_redemption, un usuario que dejó expirar un canje no volvería a reservar NUNCA. Es el
-- escenario que quedó anotado al cerrar T3 y la trampa más fácil de pisar de toda la tarea.
-- ---------------------------------------------------------------------------

reset role;

insert into public.redemptions
  (id, user_id, entitlement_id, benefit_id, merchant_id, codigo, estado,
   created_at, expira_at, franja, dia_operativo)
values ('7e5c4444-0000-4000-a000-000000000001',
        '7e5c0000-0000-4000-a000-000000000001',
        '7e5c3333-0000-4000-a000-000000000012',
        '7e5c2222-0000-4000-a000-000000000001',
        '7e5c1111-0000-4000-a000-000000000001',
        '999001', 'pendiente',
        now() - interval '30 minutes', now() - interval '25 minutes',
        app.franja_en(now() - interval '30 minutes'),
        app.dia_operativo(now() - interval '30 minutes'));

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"7e5c0000-0000-4000-a000-000000000001","role":"authenticated"}';

do $$
declare r record; v_est public.redemption_estado;
begin
  select * into r from public.create_redemption('7e5c2222-0000-4000-a000-000000000002');

  if r.redemption_id is null then
    raise exception 'FALLA: un pendiente vencido sin marcar dejó al usuario sin poder reservar';
  end if;

  select estado into v_est from public.redemptions
  where id = '7e5c4444-0000-4000-a000-000000000001';

  if v_est <> 'expirado' then
    raise exception 'FALLA: el barrido no marcó el vencido (quedó %)', v_est;
  end if;

  perform public.cancel_redemption(r.redemption_id);
end $$;

-- ---------------------------------------------------------------------------
-- 7. Sin giros y beneficio inexistente
-- ---------------------------------------------------------------------------

do $$
declare v_detalle text; v_ok boolean := false;
begin
  -- El usuario 3 tiene su pase en pendiente_activacion con 9 giros, así que sí puede.
  -- Para el caso "sin giros" se lo deja seco.
  set local request.jwt.claims =
    '{"sub":"7e5c0000-0000-4000-a000-000000000003","role":"authenticated"}';

  begin
    perform * from public.create_redemption('7e5c2222-0000-4000-a000-000000000001');
  exception when sqlstate 'P0001' then
    get stacked diagnostics v_detalle = pg_exception_detail;
    v_ok := (v_detalle = 'sin_giros');
  end;

  -- Todavía tiene giros: acá se espera que NO falle por saldo.
  if v_ok then
    raise exception 'FALLA: dijo sin_giros a alguien que tiene un pase sin estrenar con 9 giros';
  end if;
end $$;

reset role;
update public.entitlements set estado = 'cancelado'
where user_id = '7e5c0000-0000-4000-a000-000000000003';
delete from public.redemptions where user_id = '7e5c0000-0000-4000-a000-000000000003';

set local role authenticated;

do $$
declare v_detalle text; v_ok boolean := false;
begin
  set local request.jwt.claims =
    '{"sub":"7e5c0000-0000-4000-a000-000000000003","role":"authenticated"}';
  begin
    perform * from public.create_redemption('7e5c2222-0000-4000-a000-000000000001');
  exception when sqlstate 'P0001' then
    get stacked diagnostics v_detalle = pg_exception_detail;
    v_ok := (v_detalle = 'sin_giros');
  end;

  if not v_ok then
    raise exception 'FALLA: dejó reservar a un usuario sin giros (detalle: %)',
      coalesce(v_detalle, 'ninguno, no rechazó');
  end if;
end $$;

do $$
declare v_detalle text; v_ok boolean := false;
begin
  set local request.jwt.claims =
    '{"sub":"7e5c0000-0000-4000-a000-000000000001","role":"authenticated"}';
  begin
    perform * from public.create_redemption('00000000-0000-4000-a000-0000000000ff');
  exception when sqlstate 'P0001' then
    get stacked diagnostics v_detalle = pg_exception_detail;
    v_ok := (v_detalle = 'beneficio_inexistente');
  end;

  if not v_ok then
    raise exception 'FALLA: aceptó un beneficio que no existe (detalle: %)',
      coalesce(v_detalle, 'ninguno, no rechazó');
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 8. Cupo agotado: la reserva se rechaza aunque el usuario tenga giros
--
-- Se agota el cupo del día del beneficio con canjes de OTRO usuario, para que lo que bloquee sea el
-- cupo del local y no la franja del que reserva.
-- ---------------------------------------------------------------------------

reset role;

insert into auth.users (id, instance_id, aud, role, phone, phone_confirmed_at, created_at, updated_at)
values ('7e5c0000-0000-4000-a000-000000000004', '00000000-0000-0000-0000-000000000000',
        'authenticated', 'authenticated', '+56900000104', now(), now(), now());
insert into public.users (id, telefono, nombre)
values ('7e5c0000-0000-4000-a000-000000000004', '+56900000104', 'Agotador');
insert into public.entitlements (id, user_id, tipo, giros_totales, giros_usados, estado, fecha_activacion)
values ('7e5c3333-0000-4000-a000-000000000041', '7e5c0000-0000-4000-a000-000000000004',
        'pase_3', 9, 0, 'activo', now());

-- cupos_dia = 2: dos validados lo agotan.
insert into public.redemptions
  (user_id, entitlement_id, benefit_id, merchant_id, codigo, estado,
   created_at, expira_at, validado_at, franja, dia_operativo)
select '7e5c0000-0000-4000-a000-000000000004',
       '7e5c3333-0000-4000-a000-000000000041',
       '7e5c2222-0000-4000-a000-000000000002',
       '7e5c1111-0000-4000-a000-000000000002',
       c, 'validado',
       now() - interval '2 hours', now() - interval '2 hours' + interval '5 minutes',
       now() - interval '2 hours' + interval '1 minute',
       app.franja_en(now()), app.dia_operativo(now())
from (values ('999101'), ('999102')) as t(c);

set local role authenticated;

do $$
declare v_detalle text; v_ok boolean := false;
begin
  set local request.jwt.claims =
    '{"sub":"7e5c0000-0000-4000-a000-000000000001","role":"authenticated"}';
  begin
    perform * from public.create_redemption('7e5c2222-0000-4000-a000-000000000002');
  exception when sqlstate 'P0001' then
    get stacked diagnostics v_detalle = pg_exception_detail;
    v_ok := (v_detalle = 'beneficio_no_disponible');
  end;

  if not v_ok then
    raise exception 'FALLA: reservó sobre un cupo del día agotado (detalle: %)',
      coalesce(v_detalle, 'ninguno, no rechazó');
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 9. El QR firmado
--
-- Formato v1.<redemption>.<merchant>.<epoch>.<hmac>, y la firma tiene que verificar contra el
-- secreto de ESE comercio. Es lo que va a permitir validar sin conexión en el Hito 5: si la firma no
-- cierra, el panel offline estaría aceptando códigos inventados.
-- ---------------------------------------------------------------------------

-- El canje se pide como usuario, pero la firma se verifica con rol privilegiado: `merchant_secrets`
-- está cerrada a `authenticated` y tiene que seguir estándolo — si un usuario pudiera leer el secreto
-- de un comercio, podría fabricarse canjes válidos para el panel offline. El payload viaja de un rol
-- al otro en una tabla temporal.
reset role;
create temp table t_qr (payload text) on commit drop;
grant all on table t_qr to authenticated;

set local role authenticated;

do $$
declare r record;
begin
  set local request.jwt.claims =
    '{"sub":"7e5c0000-0000-4000-a000-000000000001","role":"authenticated"}';
  select * into r from public.create_redemption('7e5c2222-0000-4000-a000-000000000001');
  insert into t_qr values (r.qr_payload);
  perform public.cancel_redemption(r.redemption_id);
end $$;

reset role;

do $$
declare
  v_payload  text;
  v_partes   text[];
  v_secreto  text;
  v_esperada text;
  v_vence    timestamptz;
begin
  select payload into v_payload from t_qr;
  v_partes := string_to_array(v_payload, '.');

  if array_length(v_partes, 1) <> 5 then
    raise exception 'FALLA: el payload tiene % campos, deberían ser 5', array_length(v_partes, 1);
  end if;

  if v_partes[1] <> 'v1' then
    raise exception 'FALLA: el payload no arranca con la versión (arranca con %)', v_partes[1];
  end if;

  -- El id y el vencimiento se contrastan contra la fila real, no contra lo que devolvió la función:
  -- así la prueba detecta también que la función devuelva una cosa y guarde otra.
  select r.expira_at into v_vence
  from public.redemptions r where r.id = v_partes[2]::uuid;

  if v_vence is null then
    raise exception 'FALLA: el payload lleva un id de canje que no existe';
  end if;

  if v_partes[3] <> '7e5c1111-0000-4000-a000-000000000001' then
    raise exception 'FALLA: el payload no lleva el comercio correcto';
  end if;

  if v_partes[4] <> extract(epoch from v_vence)::bigint::text then
    raise exception 'FALLA: el payload no lleva el vencimiento correcto';
  end if;

  if v_partes[5] !~ '^[0-9a-f]{64}$' then
    raise exception 'FALLA: la firma no es un sha256 en hex';
  end if;

  select hmac_secret into v_secreto from public.merchant_secrets
  where merchant_id = '7e5c1111-0000-4000-a000-000000000001';

  v_esperada := encode(
    extensions.hmac(array_to_string(v_partes[1:4], '.'), v_secreto, 'sha256'), 'hex');

  if v_partes[5] <> v_esperada then
    raise exception 'FALLA: la firma no verifica contra el secreto del comercio';
  end if;

  -- Y no verifica contra el secreto de OTRO comercio: si verificara, cualquier local podría validar
  -- canjes de la competencia con su propio panel offline.
  select hmac_secret into v_secreto from public.merchant_secrets
  where merchant_id = '7e5c1111-0000-4000-a000-000000000002';

  if v_partes[5] = encode(
       extensions.hmac(array_to_string(v_partes[1:4], '.'), v_secreto, 'sha256'), 'hex') then
    raise exception 'FALLA: la firma verifica con el secreto de otro comercio';
  end if;

end $$;

-- Volver a bajar a `authenticated`: la verificación de la firma se hizo con rol privilegiado y desde
-- acá se vuelve a probar como usuario. Sin esto, la prueba 11 correría como `postgres` —que salta RLS
-- por definición— y estaría dando por buena una barrera que ni siquiera se evaluó.
set local role authenticated;

-- ---------------------------------------------------------------------------
-- 10. Sin sesión no se reserva ni se cancela
-- ---------------------------------------------------------------------------

do $$
declare v_detalle text; v_ok boolean := false;
begin
  set local request.jwt.claims = '{"role":"authenticated"}';
  begin
    perform * from public.create_redemption('7e5c2222-0000-4000-a000-000000000001');
  exception when sqlstate 'P0001' then
    get stacked diagnostics v_detalle = pg_exception_detail;
    v_ok := (v_detalle = 'sin_sesion');
  end;

  if not v_ok then
    raise exception 'FALLA: reservó sin sesión iniciada (detalle: %)',
      coalesce(v_detalle, 'ninguno, no rechazó');
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 11. La escritura sigue cerrada por RLS
--
-- Las funciones son la ÚNICA puerta. Un usuario no puede insertarse un canje a mano saltándose el
-- conteo de cupos y el lock, que es lo que quedó decidido al cerrar T3.
-- ---------------------------------------------------------------------------

do $$
declare v_ok boolean := false;
begin
  set local request.jwt.claims =
    '{"sub":"7e5c0000-0000-4000-a000-000000000001","role":"authenticated"}';
  begin
    insert into public.redemptions
      (user_id, entitlement_id, benefit_id, merchant_id, codigo, estado, expira_at)
    values ('7e5c0000-0000-4000-a000-000000000001',
            '7e5c3333-0000-4000-a000-000000000012',
            '7e5c2222-0000-4000-a000-000000000001',
            '7e5c1111-0000-4000-a000-000000000001',
            '999999', 'pendiente', now() + interval '5 minutes');
  exception when insufficient_privilege or others then
    v_ok := true;
  end;

  if not v_ok then
    raise exception 'FALLA: un usuario escribió en redemptions por fuera de create_redemption';
  end if;
end $$;

reset role;

rollback;
