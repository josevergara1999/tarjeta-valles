-- Pruebas de la migración 002 — benefits, benefit_rules
--
-- Cómo se corre: pegar entero en el SQL Editor de Supabase (o `psql -f`). Crea sus propios datos,
-- comprueba y hace ROLLBACK: no deja nada en la base y se puede repetir las veces que haga falta.
--
-- Dos bloques: primero que las restricciones no dejen entrar datos con los que T4 tendría que
-- adivinar; después que el RLS aísle la oferta de cada local.
--
-- Todos los conteos van FILTRADOS a los datos que crea esta prueba. La 002 dejó 8 comercios semilla
-- en la base, así que contar tablas enteras mediría el seed, no el aislamiento.

begin;

-- ---------------------------------------------------------------------------
-- Datos de prueba. Se insertan como dueño de las tablas, que no pasa por RLS.
-- ---------------------------------------------------------------------------

insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
values
  ('11111111-1111-1111-1111-111111111111', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'dueno@fogon.test',  'x', now(), now(), now()),
  ('22222222-2222-2222-2222-222222222222', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'dueno@nevado.test', 'x', now(), now(), now()),
  ('33333333-3333-3333-3333-333333333333', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'turista@test.test', 'x', now(), now(), now());

insert into public.merchants (id, nombre, rubro, activo) values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Fogón de prueba',   'restaurante', true),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'Nevado de prueba',  'cerveceria',  true),
  ('cccccccc-cccc-cccc-cccc-cccccccccccc', 'Cerrado de prueba', 'minimarket',  false);

insert into public.merchant_users (merchant_id, auth_user_id, email, rol) values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '11111111-1111-1111-1111-111111111111', 'dueno@fogon.test',  'dueno'),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', '22222222-2222-2222-2222-222222222222', 'dueno@nevado.test', 'dueno');

insert into public.users (id, telefono, nombre) values
  ('33333333-3333-3333-3333-333333333333', '+56911111111', 'Turista');

insert into public.benefits (id, merchant_id, tipo, titulo, condicion_consumo, activo) values
  ('deadbee1-0000-4000-a000-000000000001', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'cortesia',  'Postre de prueba',   'con plato principal', true),
  ('deadbee1-0000-4000-a000-000000000002', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'descuento', 'Beneficio apagado',  null,                  false),
  ('deadbee1-0000-4000-a000-000000000003', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'cortesia',  'Schop de prueba',    'con la segunda ronda', true),
  ('deadbee1-0000-4000-a000-000000000004', 'cccccccc-cccc-cccc-cccc-cccccccccccc', 'descuento', 'De un local cerrado', null,                  true);

-- ---------------------------------------------------------------------------
-- La semilla de la 002 quedó cargada y es coherente
-- ---------------------------------------------------------------------------

do $$
declare n int;
begin
  select count(*) into n from public.merchants where id::text like '5eed0000-%';
  if n <> 8 then
    raise exception 'FALLA: la semilla dejó % comercios, deberían ser 8', n;
  end if;

  -- Uno activo por comercio, ni cero ni dos: es la decisión 4 medida sobre los datos reales.
  select count(*) into n
  from public.merchants m
  where m.id::text like '5eed0000-%'
    and (select count(*) from public.benefits b where b.merchant_id = m.id and b.activo) <> 1;
  if n <> 0 then
    raise exception 'FALLA: % comercios semilla no tienen exactamente un beneficio activo', n;
  end if;

  -- Los casos que seed-data.md pide poder probar.
  select count(*) into n
  from public.benefits b join public.benefit_rules r on r.benefit_id = b.id
  where b.id::text like '5eedbe11-%' and r.cupos_dia is null;
  if n <> 2 then
    raise exception 'FALLA: se esperaban 2 beneficios semilla sin tope diario y hay %', n;
  end if;

  select count(*) into n
  from public.benefits b join public.benefit_rules r on r.benefit_id = b.id
  where b.id::text like '5eedbe11-%' and r.hora_inicio is null;
  if n <> 1 then
    raise exception 'FALLA: se esperaba 1 beneficio semilla sin ventana horaria y hay %', n;
  end if;

  select count(*) into n
  from public.benefits
  where id::text like '5eedbe11-%' and condicion_consumo is null;
  if n <> 3 then
    raise exception 'FALLA: se esperaban 3 beneficios semilla sin condición de consumo y hay %', n;
  end if;

  raise notice 'OK  · la semilla de los 8 comercios está completa y coherente';
end $$;

-- ---------------------------------------------------------------------------
-- Invariantes del modelo
-- ---------------------------------------------------------------------------

do $$
declare n int;
begin
  -- Todo beneficio nace con sus reglas, sin que nadie las pida.
  select count(*) into n
  from public.benefits b
  where b.id::text like 'deadbee1-%'
    and not exists (select 1 from public.benefit_rules r where r.benefit_id = b.id);
  if n <> 0 then
    raise exception 'FALLA: % beneficios quedaron sin fila de reglas', n;
  end if;
  raise notice 'OK  · el trigger crea las reglas 1:1 con el beneficio';

  -- Decisión 4: dos activos en el mismo comercio, nunca.
  begin
    insert into public.benefits (merchant_id, tipo, titulo)
    values ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'descuento', 'Segundo activo');
    raise exception 'FALLA: un comercio quedó con dos beneficios activos';
  exception when unique_violation then
    raise notice 'OK  · un solo beneficio activo por comercio';
  end;

  -- Pero apagados puede tener los que quiera: el histórico no estorba.
  insert into public.benefits (merchant_id, tipo, titulo, activo)
  values ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'descuento', 'Otro apagado', false);
  raise notice 'OK  · varios beneficios apagados por comercio sí se permiten';

  -- Media ventana no significa nada.
  begin
    update public.benefit_rules set hora_inicio = '10:00', hora_fin = null
    where benefit_id = 'deadbee1-0000-4000-a000-000000000001';
    raise exception 'FALLA: se aceptó una ventana con solo una hora';
  exception when check_violation then
    raise notice 'OK  · o están las dos horas o no está ninguna';
  end;

  -- Y una ventana de inicio = fin sería ambigua para T4.
  begin
    update public.benefit_rules set hora_inicio = '10:00', hora_fin = '10:00'
    where benefit_id = 'deadbee1-0000-4000-a000-000000000001';
    raise exception 'FALLA: se aceptó una ventana degenerada';
  exception when check_violation then
    raise notice 'OK  · hora_inicio = hora_fin queda prohibido';
  end;

  -- La que SÍ tiene que entrar: la cervecería que cierra a las 02:00 (decisión 6).
  update public.benefit_rules set hora_inicio = '21:00', hora_fin = '02:00'
  where benefit_id = 'deadbee1-0000-4000-a000-000000000003';
  raise notice 'OK  · la ventana que cruza medianoche es válida';

  -- Días de la semana: vacío, fuera de rango y repetidos.
  begin
    update public.benefit_rules set dias_semana = '{}'
    where benefit_id = 'deadbee1-0000-4000-a000-000000000001';
    raise exception 'FALLA: se aceptó un beneficio sin ningún día';
  exception when check_violation then
    raise notice 'OK  · dias_semana no puede quedar vacío';
  end;

  begin
    update public.benefit_rules set dias_semana = '{1,7}'
    where benefit_id = 'deadbee1-0000-4000-a000-000000000001';
    raise exception 'FALLA: se aceptó el día 7';
  exception when check_violation then
    raise notice 'OK  · dias_semana solo admite 0-6';
  end;

  begin
    update public.benefit_rules set dias_semana = '{1,1,2}'
    where benefit_id = 'deadbee1-0000-4000-a000-000000000001';
    raise exception 'FALLA: se aceptaron días repetidos';
  exception when check_violation then
    raise notice 'OK  · dias_semana no admite repetidos';
  end;

  -- Un tope semanal por debajo del diario es un error de carga, no una regla.
  begin
    update public.benefit_rules set cupos_dia = 10, cupos_semana = 5
    where benefit_id = 'deadbee1-0000-4000-a000-000000000001';
    raise exception 'FALLA: se aceptó cupos_semana < cupos_dia';
  exception when check_violation then
    raise notice 'OK  · el tope semanal no puede ser menor que el diario';
  end;

  -- La condición vacía dejaría a la interfaz dibujando una etiqueta sin texto.
  begin
    insert into public.benefits (merchant_id, tipo, titulo, condicion_consumo, activo)
    values ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'cortesia', 'Con condición en blanco', '   ', false);
    raise exception 'FALLA: se aceptó una condición de consumo en blanco';
  exception when check_violation then
    raise notice 'OK  · la condición de consumo es nula o dice algo, nunca cadena vacía';
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
  -- Ve los suyos, encendidos y apagados, y ninguno más.
  select count(*) into n from public.benefits where merchant_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  if n <> 3 then
    raise exception 'FALLA: Fogón ve % beneficios propios, debería ver 3', n;
  end if;

  select count(*) into n from public.benefits where merchant_id <> 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  if n <> 0 then
    raise exception 'FALLA: Fogón ve % beneficios ajenos', n;
  end if;
  raise notice 'OK  · Fogón ve su oferta y no la del vecino';

  -- Ni siquiera la del seed, que es pública para el usuario final.
  select count(*) into n from public.benefit_rules;
  if n <> 3 then
    raise exception 'FALLA: Fogón ve % filas de reglas, deberían ser las 3 suyas', n;
  end if;
  raise notice 'OK  · Fogón tampoco ve las reglas ajenas';

  -- Editar lo propio, que es lo que hará T11.
  update public.benefit_rules set cupos_dia = 6
  where benefit_id = 'deadbee1-0000-4000-a000-000000000001';
  get diagnostics n = row_count;
  if n <> 1 then
    raise exception 'FALLA: Fogón no pudo editar sus propias reglas';
  end if;
  raise notice 'OK  · Fogón edita sus propias reglas';

  -- Tocar lo ajeno no da error: simplemente no alcanza ninguna fila.
  update public.benefits set titulo = 'Secuestrado'
  where id = 'deadbee1-0000-4000-a000-000000000003';
  get diagnostics n = row_count;
  if n <> 0 then
    raise exception 'FALLA: Fogón modificó % beneficios de Nevado', n;
  end if;

  update public.benefit_rules set cupos_dia = 999
  where benefit_id = 'deadbee1-0000-4000-a000-000000000003';
  get diagnostics n = row_count;
  if n <> 0 then
    raise exception 'FALLA: Fogón modificó % reglas de Nevado', n;
  end if;
  raise notice 'OK  · Fogón no puede editar el beneficio ni las reglas de Nevado';

  -- Colgarle un beneficio a otro local sí es un error, y tiene que serlo.
  begin
    insert into public.benefits (merchant_id, tipo, titulo, activo)
    values ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'descuento', 'Regalo envenenado', false);
    raise exception 'FALLA: Fogón creó un beneficio a nombre de Nevado';
  exception when insufficient_privilege then
    raise notice 'OK  · Fogón no puede crear beneficios a nombre de otro';
  end;

  -- Borrar es del admin: un beneficio con canjes detrás se apaga, no se destruye.
  delete from public.benefits where id = 'deadbee1-0000-4000-a000-000000000002';
  get diagnostics n = row_count;
  if n <> 0 then
    raise exception 'FALLA: Fogón borró % beneficios', n;
  end if;
  raise notice 'OK  · el comercio no borra beneficios, los apaga';
end $$;

-- ---------------------------------------------------------------------------
-- Con el token de un usuario final
-- ---------------------------------------------------------------------------

set local request.jwt.claims = '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}';

do $$
declare n int;
begin
  -- De los cuatro de la prueba ve dos: el apagado no, y el del local cerrado tampoco.
  select count(*) into n from public.benefits where id::text like 'deadbee1-%';
  if n <> 2 then
    raise exception 'FALLA: el usuario ve % beneficios de prueba, deberían ser 2', n;
  end if;

  select count(*) into n from public.benefits
  where id = 'deadbee1-0000-4000-a000-000000000002';
  if n <> 0 then
    raise exception 'FALLA: el usuario ve un beneficio apagado';
  end if;

  select count(*) into n from public.benefits
  where id = 'deadbee1-0000-4000-a000-000000000004';
  if n <> 0 then
    raise exception 'FALLA: el usuario ve el beneficio de un comercio cerrado';
  end if;
  raise notice 'OK  · el usuario ve solo beneficios activos de comercios activos';

  -- Y ve la red semilla entera, que es lo que va a dibujar la ruleta.
  select count(*) into n from public.benefits where id::text like '5eedbe11-%';
  if n <> 8 then
    raise exception 'FALLA: el usuario ve % beneficios de la red semilla, deberían ser 8', n;
  end if;

  select count(*) into n from public.benefit_rules r
  join public.benefits b on b.id = r.benefit_id
  where b.id::text like '5eedbe11-%';
  if n <> 8 then
    raise exception 'FALLA: el usuario ve % reglas de la red semilla, deberían ser 8', n;
  end if;
  raise notice 'OK  · el usuario ve los 8 beneficios de la red con sus reglas';

  -- Pero no toca nada.
  update public.benefits set titulo = 'Gratis total'
  where id = 'deadbee1-0000-4000-a000-000000000001';
  get diagnostics n = row_count;
  if n <> 0 then
    raise exception 'FALLA: un usuario editó % beneficios', n;
  end if;

  update public.benefit_rules set cupos_dia = 9999
  where benefit_id = 'deadbee1-0000-4000-a000-000000000001';
  get diagnostics n = row_count;
  if n <> 0 then
    raise exception 'FALLA: un usuario se subió el cupo en % reglas', n;
  end if;
  raise notice 'OK  · el usuario no edita beneficios ni cupos';

  begin
    insert into public.benefits (merchant_id, tipo, titulo, activo)
    values ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'cortesia', 'Beneficio inventado', false);
    raise exception 'FALLA: un usuario final creó un beneficio';
  exception when insufficient_privilege then
    raise notice 'OK  · un usuario final no puede crear beneficios';
  end;
end $$;

reset role;

do $$ begin raise notice 'TODO OK · la migración 002 aísla lo que debe aislar'; end $$;

rollback;
