-- Pruebas de las migraciones 005 y 006 — entitlements, redemptions
--
-- Cómo se corre: pegar entero en el SQL Editor de Supabase (o `psql -f`). Crea sus propios datos,
-- comprueba y hace ROLLBACK: no deja nada en la base y se puede repetir las veces que haga falta.
--
-- Tres bloques: que la semilla quedó como pide seed-data.md, que las restricciones sostienen la
-- regla antifraude sin depender de T5/T6, y que el RLS aísla canjes y clientes entre comercios.
--
-- Los conteos van FILTRADOS a los datos de esta prueba: la base trae la red semilla y sus canjes.

begin;

-- ---------------------------------------------------------------------------
-- La semilla de usuarios es la que describe seed-data.md
-- ---------------------------------------------------------------------------

do $$
declare n int; giros int;
begin
  select count(*) into n from public.users where id::text like '5eed0002-%';
  if n <> 5 then
    raise exception 'FALLA: la semilla dejó % usuarios, deberían ser 5', n;
  end if;

  -- Usuario nuevo: sin entitlements, para que T7 tenga a quién darle el giro de bienvenida.
  select count(*) into n from public.entitlements
  where user_id = '5eed0002-0000-4000-a000-000000000001';
  if n <> 0 then
    raise exception 'FALLA: el usuario nuevo nació con % entitlements', n;
  end if;

  -- Turista con pase: 3 giros usados y 2 locales en cooldown (escenario 4).
  select count(*) into n from public.redemptions
  where user_id = '5eed0002-0000-4000-a000-000000000002' and estado = 'validado';
  if n <> 3 then
    raise exception 'FALLA: el turista tiene % canjes validados, deberían ser 3', n;
  end if;

  select count(distinct merchant_id) into n from public.redemptions
  where user_id = '5eed0002-0000-4000-a000-000000000002'
    and estado = 'validado'
    and validado_at > now() - interval '3 days';
  if n <> 2 then
    raise exception 'FALLA: el turista tiene % locales en cooldown, deberían ser 2', n;
  end if;

  -- Suscriptora: 8 canjes históricos, cerca del Nivel 1 (10) sin haberlo cruzado.
  select count(*) into n from public.redemptions
  where user_id = '5eed0002-0000-4000-a000-000000000003' and estado = 'validado';
  if n <> 8 then
    raise exception 'FALLA: la suscriptora tiene % canjes, deberían ser 8', n;
  end if;

  -- Nivel 1: 34 canjes, por encima del umbral de 10 y por debajo del de 35.
  select count(*) into n from public.redemptions
  where user_id = '5eed0002-0000-4000-a000-000000000004' and estado = 'validado';
  if n <> 34 then
    raise exception 'FALLA: el cliente Nivel 1 tiene % canjes, deberían ser 34', n;
  end if;

  -- Pase vencido: se quedó con un giro dentro, y no cuenta como disponible.
  select coalesce(sum(giros_totales - giros_usados), 0) into giros
  from public.entitlements
  where user_id = '5eed0002-0000-4000-a000-000000000005' and estado = 'activo';
  if giros <> 0 then
    raise exception 'FALLA: el pase vencido ofrece % giros disponibles, debería ofrecer 0', giros;
  end if;

  raise notice 'OK  · los 5 usuarios semilla están como los describe seed-data.md';
end $$;

-- ---------------------------------------------------------------------------
-- Datos de prueba propios
-- ---------------------------------------------------------------------------

insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
values
  ('11111111-1111-1111-1111-111111111111', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'dueno@fogon.test',  'x', now(), now(), now()),
  ('22222222-2222-2222-2222-222222222222', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'dueno@nevado.test', 'x', now(), now(), now()),
  ('33333333-3333-3333-3333-333333333333', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'turista@test.test', 'x', now(), now(), now()),
  ('44444444-4444-4444-4444-444444444444', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'otro@test.test',    'x', now(), now(), now());

insert into public.merchants (id, nombre, rubro, activo) values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Fogón de prueba',  'restaurante', true),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'Nevado de prueba', 'cerveceria',  true);

insert into public.merchant_users (merchant_id, auth_user_id, email, rol) values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '11111111-1111-1111-1111-111111111111', 'dueno@fogon.test',  'dueno'),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', '22222222-2222-2222-2222-222222222222', 'dueno@nevado.test', 'dueno');

insert into public.users (id, telefono, nombre) values
  ('33333333-3333-3333-3333-333333333333', '+56900000001', 'Turista'),
  ('44444444-4444-4444-4444-444444444444', '+56900000002', 'Otro turista');

insert into public.benefits (id, merchant_id, tipo, titulo, condicion_consumo) values
  ('deadbee1-0000-4000-a000-000000000001', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'cortesia', 'Postre de prueba', 'con plato principal'),
  ('deadbee1-0000-4000-a000-000000000002', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'cortesia', 'Schop de prueba',  'con la segunda ronda');

insert into public.entitlements (id, user_id, tipo, giros_totales, giros_usados, estado, fecha_activacion)
values
  ('ee000000-0000-4000-a000-000000000001', '33333333-3333-3333-3333-333333333333', 'pase_7', 5, 0, 'activo', now()),
  ('ee000000-0000-4000-a000-000000000002', '44444444-4444-4444-4444-444444444444', 'pase_7', 5, 0, 'activo', now());

-- Un canje del turista en Fogón, todavía pendiente.
insert into public.redemptions (id, user_id, entitlement_id, benefit_id, merchant_id, codigo, estado, expira_at)
values
  ('cc000000-0000-4000-a000-000000000001', '33333333-3333-3333-3333-333333333333',
   'ee000000-0000-4000-a000-000000000001', 'deadbee1-0000-4000-a000-000000000001',
   'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '654321', 'pendiente', now() + interval '5 minutes');

-- ---------------------------------------------------------------------------
-- Las reglas que sostienen el antifraude, medidas contra la base
-- ---------------------------------------------------------------------------

do $$
begin
  -- Saldo: nadie gasta más giros de los que compró.
  begin
    update public.entitlements set giros_usados = 6
    where id = 'ee000000-0000-4000-a000-000000000001';
    raise exception 'FALLA: se gastaron más giros de los comprados';
  exception when check_violation then
    raise notice 'OK  · giros_usados no puede pasar de giros_totales';
  end;

  -- Decisión 10: el giro de bienvenida es uno por usuario y de por vida.
  insert into public.entitlements (user_id, tipo, giros_totales, estado)
  values ('33333333-3333-3333-3333-333333333333', 'bienvenida', 1, 'pendiente_activacion');
  begin
    insert into public.entitlements (user_id, tipo, giros_totales, estado)
    values ('33333333-3333-3333-3333-333333333333', 'bienvenida', 1, 'pendiente_activacion');
    raise exception 'FALLA: un usuario consiguió dos giros de bienvenida';
  exception when unique_violation then
    raise notice 'OK  · un solo giro de bienvenida por usuario';
  end;

  -- Decisión 2: máximo un canje pendiente por usuario.
  begin
    insert into public.redemptions (user_id, entitlement_id, benefit_id, merchant_id, codigo, estado, expira_at)
    values ('33333333-3333-3333-3333-333333333333', 'ee000000-0000-4000-a000-000000000001',
            'deadbee1-0000-4000-a000-000000000002', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
            '111111', 'pendiente', now() + interval '5 minutes');
    raise exception 'FALLA: un usuario abrió dos canjes pendientes a la vez';
  exception when unique_violation then
    raise notice 'OK  · un solo canje pendiente por usuario';
  end;

  -- El código es único mientras está vigente...
  begin
    insert into public.redemptions (user_id, entitlement_id, benefit_id, merchant_id, codigo, estado, expira_at)
    values ('44444444-4444-4444-4444-444444444444', 'ee000000-0000-4000-a000-000000000002',
            'deadbee1-0000-4000-a000-000000000002', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
            '654321', 'pendiente', now() + interval '5 minutes');
    raise exception 'FALLA: dos canjes pendientes con el mismo código';
  exception when unique_violation then
    raise notice 'OK  · el código no se repite entre canjes vigentes';
  end;

  -- ...y libre en el histórico: seis dígitos se agotan rápido y un canje validado no se reusa.
  insert into public.redemptions (user_id, entitlement_id, benefit_id, merchant_id, codigo, estado, expira_at, validado_at)
  values ('44444444-4444-4444-4444-444444444444', 'ee000000-0000-4000-a000-000000000002',
          'deadbee1-0000-4000-a000-000000000002', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
          '654321', 'validado', now() + interval '5 minutes', now());
  raise notice 'OK  · el código sí se puede repetir en el histórico';

  -- Seis dígitos, ni cinco ni letras: es lo que se teclea en el mesón.
  begin
    insert into public.redemptions (user_id, entitlement_id, benefit_id, merchant_id, codigo, estado, expira_at)
    values ('44444444-4444-4444-4444-444444444444', 'ee000000-0000-4000-a000-000000000002',
            'deadbee1-0000-4000-a000-000000000002', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
            'ABC12', 'pendiente', now() + interval '5 minutes');
    raise exception 'FALLA: se aceptó un código que no son 6 dígitos';
  exception when check_violation then
    raise notice 'OK  · el código son exactamente 6 dígitos';
  end;

  -- Escenario 9 de seed-data.md, cerrado en la base: el beneficio tiene que ser de ese comercio.
  begin
    insert into public.redemptions (user_id, entitlement_id, benefit_id, merchant_id, codigo, estado, expira_at)
    values ('44444444-4444-4444-4444-444444444444', 'ee000000-0000-4000-a000-000000000002',
            'deadbee1-0000-4000-a000-000000000001', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
            '222222', 'pendiente', now() + interval '5 minutes');
    raise exception 'FALLA: se canjeó el beneficio de Fogón a nombre de Nevado';
  exception when foreign_key_violation then
    raise notice 'OK  · un canje no puede mezclar el beneficio de un local con otro';
  end;

  -- Migración 006: el giro que se gasta es del que canjea, no del de al lado.
  begin
    insert into public.redemptions (user_id, entitlement_id, benefit_id, merchant_id, codigo, estado, expira_at)
    values ('44444444-4444-4444-4444-444444444444', 'ee000000-0000-4000-a000-000000000001',
            'deadbee1-0000-4000-a000-000000000002', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
            '333333', 'pendiente', now() + interval '5 minutes');
    raise exception 'FALLA: un canje descontó el giro de otro usuario';
  exception when foreign_key_violation then
    raise notice 'OK  · el canje solo gasta giros de su propio dueño';
  end;

  -- Un validado sin hora dejaría al cooldown sin desde cuándo contar.
  begin
    update public.redemptions set estado = 'validado', validado_at = null
    where id = 'cc000000-0000-4000-a000-000000000001';
    raise exception 'FALLA: se validó un canje sin hora de validación';
  exception when check_violation then
    raise notice 'OK  · un canje validado siempre tiene validado_at';
  end;

  -- La anulación es de soporte: sin motivo y sin responsable, no se anula.
  begin
    update public.redemptions set estado = 'anulado'
    where id = 'cc000000-0000-4000-a000-000000000001';
    raise exception 'FALLA: se anuló un canje sin motivo ni responsable';
  exception when check_violation then
    raise notice 'OK  · anular exige motivo y responsable';
  end;

  begin
    update public.redemptions set estado = 'anulado', anulado_por = '11111111-1111-1111-1111-111111111111',
                                 motivo_anulacion = '   '
    where id = 'cc000000-0000-4000-a000-000000000001';
    raise exception 'FALLA: se anuló un canje con el motivo en blanco';
  exception when check_violation then
    raise notice 'OK  · el motivo de anulación no puede ir en blanco';
  end;

  -- Y al revés: un canje que no está anulado no arrastra motivo.
  begin
    update public.redemptions set motivo_anulacion = 'me lo invento'
    where id = 'cc000000-0000-4000-a000-000000000001';
    raise exception 'FALLA: un canje no anulado quedó con motivo de anulación';
  exception when check_violation then
    raise notice 'OK  · el motivo solo existe si el canje está anulado';
  end;
end $$;

-- ---------------------------------------------------------------------------
-- Con el token de Fogón
-- ---------------------------------------------------------------------------

set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';

do $$
declare n int;
begin
  -- Escenario 7: Fogón no lee los canjes de Nevado.
  select count(*) into n from public.redemptions where merchant_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  if n <> 1 then
    raise exception 'FALLA: Fogón ve % canjes propios, debería ver 1', n;
  end if;

  select count(*) into n from public.redemptions where merchant_id <> 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  if n <> 0 then
    raise exception 'FALLA: Fogón ve % canjes ajenos', n;
  end if;
  raise notice 'OK  · Fogón lee sus canjes y ninguno más';

  -- La política que la 001 dejó pendiente: ve a su cliente, y solo a su cliente.
  select count(*) into n from public.users where id = '33333333-3333-3333-3333-333333333333';
  if n <> 1 then
    raise exception 'FALLA: Fogón no ve al cliente que tiene un canje con él';
  end if;

  select count(*) into n from public.users where id = '44444444-4444-4444-4444-444444444444';
  if n <> 0 then
    raise exception 'FALLA: Fogón ve a un usuario que nunca canjeó con él';
  end if;
  raise notice 'OK  · Fogón ve a sus clientes y a nadie más';

  -- La billetera del cliente no es asunto suyo.
  select count(*) into n from public.entitlements;
  if n <> 0 then
    raise exception 'FALLA: Fogón lee % entitlements de sus clientes', n;
  end if;
  raise notice 'OK  · el comercio no ve cuántos giros le quedan al cliente';

  -- Validar es de T6, con función firmada: por la API no se toca nada.
  update public.redemptions set estado = 'validado', validado_at = now()
  where id = 'cc000000-0000-4000-a000-000000000001';
  get diagnostics n = row_count;
  if n <> 0 then
    raise exception 'FALLA: Fogón validó % canjes por la API, saltándose T6', n;
  end if;
  raise notice 'OK  · validar no se puede por la API, solo por la función de T6';
end $$;

-- ---------------------------------------------------------------------------
-- Con el token de un usuario final
-- ---------------------------------------------------------------------------

set local request.jwt.claims = '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}';

do $$
declare n int;
begin
  select count(*) into n from public.entitlements
  where user_id <> '33333333-3333-3333-3333-333333333333';
  if n <> 0 then
    raise exception 'FALLA: el usuario lee % billeteras ajenas', n;
  end if;
  raise notice 'OK  · el usuario solo ve su propia billetera';

  select count(*) into n from public.redemptions
  where user_id <> '33333333-3333-3333-3333-333333333333';
  if n <> 0 then
    raise exception 'FALLA: el usuario lee % canjes ajenos', n;
  end if;
  raise notice 'OK  · el usuario solo ve sus propios canjes';

  -- Regalarse giros, no.
  update public.entitlements set giros_totales = 999
  where id = 'ee000000-0000-4000-a000-000000000001';
  get diagnostics n = row_count;
  if n <> 0 then
    raise exception 'FALLA: un usuario se regaló giros en % filas', n;
  end if;
  raise notice 'OK  · el usuario no se puede regalar giros';

  -- Ni saltarse la reserva escribiendo el canje a mano: eso es T5, con lock.
  begin
    insert into public.redemptions (user_id, entitlement_id, benefit_id, merchant_id, codigo, estado, expira_at)
    values ('33333333-3333-3333-3333-333333333333', 'ee000000-0000-4000-a000-000000000001',
            'deadbee1-0000-4000-a000-000000000002', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
            '999999', 'pendiente', now() + interval '5 minutes');
    raise exception 'FALLA: un usuario creó un canje por la API, saltándose T5';
  exception when insufficient_privilege then
    raise notice 'OK  · crear canjes no se puede por la API, solo por la función de T5';
  end;

  -- Y no puede darse por validado su propio canje.
  update public.redemptions set estado = 'validado', validado_at = now()
  where id = 'cc000000-0000-4000-a000-000000000001';
  get diagnostics n = row_count;
  if n <> 0 then
    raise exception 'FALLA: un usuario se validó % canjes solo', n;
  end if;
  raise notice 'OK  · el usuario no se valida sus propios canjes';
end $$;

reset role;

do $$ begin raise notice 'TODO OK · las migraciones 005 y 006 aíslan y sostienen el antifraude'; end $$;

rollback;
