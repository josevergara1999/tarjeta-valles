-- Pruebas de las migraciones 008 y 009 — franjas, día operativo y get_available_benefits
--
-- Cómo se corre: pegar entero en el SQL Editor de Supabase (o `psql -f`). Crea sus propios datos,
-- comprueba y hace ROLLBACK: no deja nada en la base y se puede repetir las veces que haga falta.
--
-- Cuatro bloques: el cálculo de franja y día operativo (incluida la madrugada), el techo de ritmo
-- en modo franjas, el mismo caso en modo libre, y las cinco condiciones de disponibilidad.

begin;

-- ---------------------------------------------------------------------------
-- 1. Franja y día operativo
--
-- El caso que importa es la madrugada: a la 01:00 todavía es la noche de AYER. Si esto se rompe,
-- la cervecería de 21:00 a 02:00 pierde a su clientela de la última hora y los cupos del día se
-- parten en dos.
-- ---------------------------------------------------------------------------

do $$
declare
  -- Instantes expresados en hora del valle y convertidos, para que la prueba no dependa de la
  -- zona horaria del servidor donde se corra.
  t_manana timestamptz := ('2026-08-30 08:30'::timestamp at time zone 'America/Santiago');
  t_tarde  timestamptz := ('2026-08-30 14:00'::timestamp at time zone 'America/Santiago');
  t_noche  timestamptz := ('2026-08-30 22:00'::timestamp at time zone 'America/Santiago');
  t_madrug timestamptz := ('2026-08-31 01:00'::timestamp at time zone 'America/Santiago');
  t_borde  timestamptz := ('2026-08-31 06:00'::timestamp at time zone 'America/Santiago');
begin
  if app.franja_en(t_manana) <> 'manana' then
    raise exception 'FALLA: las 08:30 deberían ser mañana, dieron %', app.franja_en(t_manana);
  end if;

  if app.franja_en(t_tarde) <> 'tarde' then
    raise exception 'FALLA: las 14:00 deberían ser tarde, dieron %', app.franja_en(t_tarde);
  end if;

  if app.franja_en(t_noche) <> 'noche' then
    raise exception 'FALLA: las 22:00 deberían ser noche, dieron %', app.franja_en(t_noche);
  end if;

  -- El corazón de la decisión 6.
  if app.franja_en(t_madrug) <> 'noche' then
    raise exception 'FALLA: la 01:00 debería ser noche (la de ayer), dio %', app.franja_en(t_madrug);
  end if;

  if app.dia_operativo(t_madrug) <> date '2026-08-30' then
    raise exception 'FALLA: la 01:00 del 31 pertenece al día operativo del 30, dio %',
      app.dia_operativo(t_madrug);
  end if;

  -- Las 06:00 clavadas ya son el día nuevo: el borde es cerrado por abajo.
  if app.dia_operativo(t_borde) <> date '2026-08-31' then
    raise exception 'FALLA: las 06:00 abren el día nuevo, dieron %', app.dia_operativo(t_borde);
  end if;

  if app.franja_en(t_borde) <> 'manana' then
    raise exception 'FALLA: las 06:00 clavadas ya son mañana, dieron %', app.franja_en(t_borde);
  end if;

  -- La semana de los cupos es lunes a domingo. El 30-ago-2026 es domingo: su lunes es el 24.
  if app.semana_operativa(t_manana) <> date '2026-08-24' then
    raise exception 'FALLA: el lunes de la semana del domingo 30 es el 24, dio %',
      app.semana_operativa(t_manana);
  end if;

  -- Y el canje de la madrugada del lunes 31 cae en la semana ANTERIOR, porque su día operativo
  -- sigue siendo el domingo 30. Es la consecuencia menos obvia del día que empieza a las 06:00,
  -- y es la correcta: esa cerveza se sirvió la noche del domingo.
  if app.semana_operativa(t_madrug) <> date '2026-08-24' then
    raise exception 'FALLA: la madrugada del lunes cuenta en la semana del domingo, dio %',
      app.semana_operativa(t_madrug);
  end if;

  -- La próxima franja después de la mañana es la tarde, del mismo día.
  if app.proxima_franja_at(t_manana)
     <> ('2026-08-30 12:00'::timestamp at time zone 'America/Santiago') then
    raise exception 'FALLA: después de las 08:30 abre la tarde a las 12:00, dio %',
      app.proxima_franja_at(t_manana);
  end if;

  -- Y después de la noche, la mañana del día siguiente.
  if app.proxima_franja_at(t_noche)
     <> ('2026-08-31 06:00'::timestamp at time zone 'America/Santiago') then
    raise exception 'FALLA: después de las 22:00 abre la mañana del 31, dio %',
      app.proxima_franja_at(t_noche);
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Datos de la prueba
--
-- Un usuario propio y un comercio propio, con ids reconocibles, para no depender de la semilla ni
-- ensuciar sus conteos.
-- ---------------------------------------------------------------------------

insert into auth.users (id, instance_id, aud, role, phone, phone_confirmed_at, created_at, updated_at)
values ('7e570000-0000-4000-a000-000000000001',
        '00000000-0000-0000-0000-000000000000',
        'authenticated', 'authenticated', '+56900000001', now(), now(), now());

insert into public.users (id, telefono, nombre)
values ('7e570000-0000-4000-a000-000000000001', '+56900000001', 'Usuario T4');

insert into public.merchants (id, nombre, rubro, activo, cooldown_dias)
values ('7e571111-0000-4000-a000-000000000001', 'Local de prueba T4', 'restaurante', true, 3);

insert into public.benefits (id, merchant_id, tipo, titulo, condicion_consumo, activo)
values ('7e572222-0000-4000-a000-000000000001',
        '7e571111-0000-4000-a000-000000000001',
        'descuento', 'Beneficio de prueba', 'Sin condiciones', true);

-- El trigger de la 002 ya creó su fila de benefit_rules: acá solo se ajusta.
update public.benefit_rules
set cupos_dia = 2, cupos_semana = 5, dias_semana = '{0,1,2,3,4,5,6}',
    hora_inicio = null, hora_fin = null
where benefit_id = '7e572222-0000-4000-a000-000000000001';

insert into public.entitlements
  (id, user_id, tipo, giros_totales, giros_usados, estado, fecha_activacion)
values ('7e573333-0000-4000-a000-000000000001',
        '7e570000-0000-4000-a000-000000000001',
        'pase_3', 9, 0, 'activo', now());

-- ---------------------------------------------------------------------------
-- 2. Modo franjas: gastar la franja actual cierra la ruleta hasta la siguiente
-- ---------------------------------------------------------------------------

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"7e570000-0000-4000-a000-000000000001","role":"authenticated"}';

do $$
declare st record; n int;
begin
  select * into st from public.get_turn_state();

  if st.motivo <> 'disponible' then
    raise exception 'FALLA: usuario con 9 giros y sin canjes debería poder girar, dio %', st.motivo;
  end if;

  if st.giros_disponibles <> 9 then
    raise exception 'FALLA: debería tener 9 giros disponibles, tiene %', st.giros_disponibles;
  end if;

  select count(*) into n from public.get_available_benefits()
  where benefit_id = '7e572222-0000-4000-a000-000000000001';
  if n <> 1 then
    raise exception 'FALLA: el beneficio de prueba debería estar disponible';
  end if;
end $$;

reset role;

-- Un canje validado en la franja actual. Ojo: giros_usados sube al validar (regla dura 3).
insert into public.redemptions
  (user_id, entitlement_id, benefit_id, merchant_id, codigo, estado,
   expira_at, validado_at, franja, dia_operativo)
values ('7e570000-0000-4000-a000-000000000001',
        '7e573333-0000-4000-a000-000000000001',
        '7e572222-0000-4000-a000-000000000001',
        '7e571111-0000-4000-a000-000000000001',
        '100001', 'validado',
        now() + interval '5 minutes', now(),
        app.franja_en(now()), app.dia_operativo(now()));

update public.entitlements set giros_usados = 1
where id = '7e573333-0000-4000-a000-000000000001';

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"7e570000-0000-4000-a000-000000000001","role":"authenticated"}';

do $$
declare st record; n int;
begin
  select * into st from public.get_turn_state();

  if st.motivo <> 'franja_gastada' then
    raise exception 'FALLA: gastada la franja, el motivo debería ser franja_gastada, dio %',
      st.motivo;
  end if;

  -- Le quedan 8 giros: la franja es un techo de RITMO, no una fuente de giros.
  if st.giros_disponibles <> 8 then
    raise exception 'FALLA: debería quedarle 8 giros, tiene %', st.giros_disponibles;
  end if;

  if st.proxima_franja_at <= now() then
    raise exception 'FALLA: la próxima franja debería estar en el futuro';
  end if;

  -- Y la ruleta se cierra ENTERA, no solo la casilla de ese local.
  select count(*) into n from public.get_available_benefits();
  if n <> 0 then
    raise exception 'FALLA: con la franja gastada no debería haber ninguna casilla, hay %', n;
  end if;
end $$;

reset role;

-- ---------------------------------------------------------------------------
-- 3. Modo libre: el mismo usuario, el mismo canje, otro techo
--
-- Cambiar el ritmo del producto tiene que ser un update en settings. Si esta prueba pasa, el modo
-- libre está realmente disponible para probarlo sin migración ni despliegue.
-- ---------------------------------------------------------------------------

update public.settings set value = 'libre' where key = 'modo_ritmo_giros';

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"7e570000-0000-4000-a000-000000000001","role":"authenticated"}';

do $$
declare st record;
begin
  select * into st from public.get_turn_state();

  if st.modo <> 'libre' then
    raise exception 'FALLA: el modo debería ser libre, es %', st.modo;
  end if;

  -- Con un solo canje del día y un techo de 3, sigue pudiendo girar.
  if st.motivo <> 'disponible' then
    raise exception 'FALLA: en modo libre, 1 canje de 3 no debería cerrar la ruleta, dio %',
      st.motivo;
  end if;
end $$;

reset role;

-- Bajar el techo a 1 tiene que cerrarla de inmediato, sin tocar nada más.
update public.settings set value = '1' where key = 'giros_por_dia';

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"7e570000-0000-4000-a000-000000000001","role":"authenticated"}';

do $$
declare st record;
begin
  select * into st from public.get_turn_state();
  if st.motivo <> 'techo_diario' then
    raise exception 'FALLA: con techo 1 y un canje hecho, debería dar techo_diario, dio %',
      st.motivo;
  end if;
end $$;

reset role;

update public.settings set value = 'franjas' where key = 'modo_ritmo_giros';
update public.settings set value = '3' where key = 'giros_por_dia';

-- ---------------------------------------------------------------------------
-- 4. Las cinco condiciones
--
-- El canje de arriba dejó al local en cooldown, así que primero hay que sacarlo del medio para
-- poder probar las demás condiciones por separado.
-- ---------------------------------------------------------------------------

-- Cooldown: el local se apaga 3 días desde validado_at.
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"7e570000-0000-4000-a000-000000000001","role":"authenticated"}';

do $$
declare n int;
begin
  -- Se mira solo el beneficio de prueba: la franja gastada ya vació la ruleta, así que esta
  -- comprobación se hace más abajo, con el canje movido en el tiempo.
  select count(*) into n from public.get_available_benefits();
  if n <> 0 then
    raise exception 'FALLA: la franja sigue gastada, no debería haber casillas';
  end if;
end $$;

reset role;

-- Se mueve el canje a la franja de ayer: libera la franja de hoy pero mantiene el cooldown vivo.
update public.redemptions
set dia_operativo = app.dia_operativo(now()) - 1,
    validado_at   = now() - interval '1 day'
where codigo = '100001';

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"7e570000-0000-4000-a000-000000000001","role":"authenticated"}';

do $$
declare st record; n int;
begin
  select * into st from public.get_turn_state();
  if st.motivo <> 'disponible' then
    raise exception 'FALLA: con el canje movido a ayer debería poder girar, dio %', st.motivo;
  end if;

  -- Pero el local sigue apagado: 1 día de 3 de cooldown.
  select count(*) into n from public.get_available_benefits()
  where benefit_id = '7e572222-0000-4000-a000-000000000001';
  if n <> 0 then
    raise exception 'FALLA: el local debería estar en cooldown (1 día de 3)';
  end if;
end $$;

reset role;

-- Pasado el cooldown, el local vuelve.
update public.redemptions
set validado_at = now() - interval '4 days'
where codigo = '100001';

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"7e570000-0000-4000-a000-000000000001","role":"authenticated"}';

do $$
declare n int;
begin
  select count(*) into n from public.get_available_benefits()
  where benefit_id = '7e572222-0000-4000-a000-000000000001';
  if n <> 1 then
    raise exception 'FALLA: pasados 4 días de cooldown el local debería volver';
  end if;
end $$;

reset role;

-- Día de la semana: se le quita el día operativo de hoy a la regla.
update public.benefit_rules
set dias_semana = (
  select array_agg(d)::smallint[] from generate_series(0, 6) d
  where d <> extract(dow from app.dia_operativo(now()))::smallint
)
where benefit_id = '7e572222-0000-4000-a000-000000000001';

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"7e570000-0000-4000-a000-000000000001","role":"authenticated"}';

do $$
declare n int;
begin
  select count(*) into n from public.get_available_benefits()
  where benefit_id = '7e572222-0000-4000-a000-000000000001';
  if n <> 0 then
    raise exception 'FALLA: el beneficio no opera hoy, no debería aparecer';
  end if;
end $$;

reset role;

update public.benefit_rules set dias_semana = '{0,1,2,3,4,5,6}'
where benefit_id = '7e572222-0000-4000-a000-000000000001';

-- Ventana horaria que cruza medianoche: se arma una que SÍ contiene la hora actual y otra que no,
-- ambas con hora_fin < hora_inicio, que es el caso que rompe las implementaciones ingenuas.
update public.benefit_rules
set hora_inicio = app.hora_local(now()) - interval '1 hour',
    hora_fin    = app.hora_local(now()) + interval '1 hour'
where benefit_id = '7e572222-0000-4000-a000-000000000001';

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"7e570000-0000-4000-a000-000000000001","role":"authenticated"}';

do $$
declare n int;
begin
  select count(*) into n from public.get_available_benefits()
  where benefit_id = '7e572222-0000-4000-a000-000000000001';
  if n <> 1 then
    raise exception 'FALLA: la hora actual está dentro de la ventana, debería aparecer';
  end if;
end $$;

reset role;

-- Ahora una ventana que cruza medianoche y NO contiene la hora actual.
update public.benefit_rules
set hora_inicio = app.hora_local(now()) + interval '2 hours',
    hora_fin    = app.hora_local(now()) - interval '2 hours'
where benefit_id = '7e572222-0000-4000-a000-000000000001';

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"7e570000-0000-4000-a000-000000000001","role":"authenticated"}';

do $$
declare n int;
begin
  select count(*) into n from public.get_available_benefits()
  where benefit_id = '7e572222-0000-4000-a000-000000000001';
  if n <> 0 then
    raise exception 'FALLA: la hora actual está fuera de la ventana nocturna, no debería aparecer';
  end if;
end $$;

reset role;

update public.benefit_rules set hora_inicio = null, hora_fin = null
where benefit_id = '7e572222-0000-4000-a000-000000000001';

-- ---------------------------------------------------------------------------
-- 5. Cupos: validados + pendientes vigentes, y el pendiente expirado que NO cuenta
--
-- Es la decisión 1. Los canjes son de OTRO usuario, para que no toquen la franja del nuestro.
-- ---------------------------------------------------------------------------

insert into auth.users (id, instance_id, aud, role, phone, phone_confirmed_at, created_at, updated_at)
values ('7e570000-0000-4000-a000-000000000002',
        '00000000-0000-0000-0000-000000000000',
        'authenticated', 'authenticated', '+56900000002', now(), now(), now());

insert into public.users (id, telefono, nombre)
values ('7e570000-0000-4000-a000-000000000002', '+56900000002', 'Otro usuario T4');

insert into public.entitlements
  (id, user_id, tipo, giros_totales, giros_usados, estado, fecha_activacion)
values ('7e573333-0000-4000-a000-000000000002',
        '7e570000-0000-4000-a000-000000000002',
        'pase_3', 9, 0, 'activo', now());

-- cupos_dia = 2. Uno validado y uno pendiente VIGENTE deberían agotarlo.
insert into public.redemptions
  (user_id, entitlement_id, benefit_id, merchant_id, codigo, estado,
   expira_at, validado_at, franja, dia_operativo)
values
  ('7e570000-0000-4000-a000-000000000002', '7e573333-0000-4000-a000-000000000002',
   '7e572222-0000-4000-a000-000000000001', '7e571111-0000-4000-a000-000000000001',
   '100002', 'validado', now() + interval '5 minutes', now(),
   app.franja_en(now()), app.dia_operativo(now())),
  ('7e570000-0000-4000-a000-000000000002', '7e573333-0000-4000-a000-000000000002',
   '7e572222-0000-4000-a000-000000000001', '7e571111-0000-4000-a000-000000000001',
   '100003', 'pendiente', now() + interval '5 minutes', null,
   app.franja_en(now()), app.dia_operativo(now()));

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"7e570000-0000-4000-a000-000000000001","role":"authenticated"}';

do $$
declare n int;
begin
  select count(*) into n from public.get_available_benefits()
  where benefit_id = '7e572222-0000-4000-a000-000000000001';
  if n <> 0 then
    raise exception 'FALLA: cupo del día agotado (1 validado + 1 pendiente vigente), no debería aparecer';
  end if;
end $$;

reset role;

-- El pendiente expira: libera su cupo al vuelo, sin cron (decisión 8).
--
-- Hay que retroceder AMBAS fechas, no solo `expira_at`. La 005 tiene el check
-- `redemptions_expira_despues_de_crearse`, y un canje creado ahora que expiró hace un minuto es
-- justamente lo que esa restricción existe para impedir. Se simula lo que pasa de verdad: el canje
-- se creó hace diez minutos y venció hace cinco.
update public.redemptions
set created_at = now() - interval '10 minutes',
    expira_at  = now() - interval '5 minutes'
where codigo = '100003';

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"7e570000-0000-4000-a000-000000000001","role":"authenticated"}';

do $$
declare n int; cupos int;
begin
  select count(*) into n from public.get_available_benefits()
  where benefit_id = '7e572222-0000-4000-a000-000000000001';
  if n <> 1 then
    raise exception 'FALLA: el pendiente vencido libera su cupo, el beneficio debería volver';
  end if;

  select cupos_restantes_dia into cupos from public.get_available_benefits()
  where benefit_id = '7e572222-0000-4000-a000-000000000001';
  if cupos <> 1 then
    raise exception 'FALLA: debería quedar 1 cupo de 2, quedan %', cupos;
  end if;
end $$;

reset role;

-- ---------------------------------------------------------------------------
-- 6. Saldo y canje pendiente propio
-- ---------------------------------------------------------------------------

-- Un pendiente propio y vigente bloquea la ruleta entera (decisión 2) y ya reserva su giro,
-- aunque giros_usados todavía no haya subido.
insert into public.redemptions
  (user_id, entitlement_id, benefit_id, merchant_id, codigo, estado,
   expira_at, franja, dia_operativo)
values ('7e570000-0000-4000-a000-000000000001', '7e573333-0000-4000-a000-000000000001',
        '7e572222-0000-4000-a000-000000000001', '7e571111-0000-4000-a000-000000000001',
        '100004', 'pendiente', now() + interval '5 minutes',
        app.franja_en(now()), app.dia_operativo(now()));

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"7e570000-0000-4000-a000-000000000001","role":"authenticated"}';

do $$
declare st record;
begin
  select * into st from public.get_turn_state();

  if st.motivo <> 'canje_pendiente' then
    raise exception 'FALLA: con un pendiente vigente el motivo debería ser canje_pendiente, dio %',
      st.motivo;
  end if;

  if st.canje_pendiente_id is null then
    raise exception 'FALLA: get_turn_state debería devolver el id del canje pendiente';
  end if;

  -- 9 totales, 1 usado (el validado de más arriba), 1 reservado por el pendiente = 7.
  if st.giros_disponibles <> 7 then
    raise exception 'FALLA: el pendiente debería reservar un giro; disponibles = %',
      st.giros_disponibles;
  end if;
end $$;

reset role;

delete from public.redemptions where codigo = '100004';

-- Sin giros: se agota el pase.
update public.entitlements set giros_usados = 9
where id = '7e573333-0000-4000-a000-000000000001';

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"7e570000-0000-4000-a000-000000000001","role":"authenticated"}';

do $$
declare st record; n int;
begin
  select * into st from public.get_turn_state();
  if st.motivo <> 'sin_giros' then
    raise exception 'FALLA: pase agotado debería dar sin_giros, dio %', st.motivo;
  end if;

  select count(*) into n from public.get_available_benefits();
  if n <> 0 then
    raise exception 'FALLA: sin giros no debería haber ninguna casilla, hay %', n;
  end if;
end $$;

reset role;

-- ---------------------------------------------------------------------------
-- 7. Comercio y beneficio apagados
-- ---------------------------------------------------------------------------

update public.entitlements set giros_usados = 1
where id = '7e573333-0000-4000-a000-000000000001';

update public.merchants set activo = false
where id = '7e571111-0000-4000-a000-000000000001';

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"7e570000-0000-4000-a000-000000000001","role":"authenticated"}';

do $$
declare n int;
begin
  select count(*) into n from public.get_available_benefits()
  where benefit_id = '7e572222-0000-4000-a000-000000000001';
  if n <> 0 then
    raise exception 'FALLA: un comercio apagado no puede aparecer en la ruleta';
  end if;
end $$;

reset role;

-- ---------------------------------------------------------------------------
-- 8. La regla dura 4: nunca un beneficio sin su condición de consumo
-- ---------------------------------------------------------------------------

update public.merchants set activo = true
where id = '7e571111-0000-4000-a000-000000000001';

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"7e570000-0000-4000-a000-000000000001","role":"authenticated"}';

do $$
declare n int;
begin
  select count(*) into n from public.get_available_benefits()
  where condicion_consumo is null or length(btrim(condicion_consumo)) = 0;
  if n <> 0 then
    raise exception 'FALLA: % casillas vienen sin condición de consumo', n;
  end if;
end $$;

reset role;

rollback;
