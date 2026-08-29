-- Pruebas negativas de RLS — migración 001
--
-- Cómo se corre: pegar entero en el SQL Editor de Supabase (o `psql -f`). Crea sus propios datos,
-- comprueba y hace ROLLBACK: no deja nada en la base y se puede repetir las veces que haga falta.
--
-- Si termina imprimiendo "TODO OK", las cuatro tablas de la 001 aíslan lo que tienen que aislar.
-- Cualquier falla corta la ejecución con un mensaje que dice qué se pudo leer y no se debía.

begin;

-- ---------------------------------------------------------------------------
-- Datos de prueba. Se insertan como dueño de las tablas, que no pasa por RLS.
-- ---------------------------------------------------------------------------

insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
values
  ('11111111-1111-1111-1111-111111111111', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'dueno@fogon.test',  'x', now(), now(), now()),
  ('22222222-2222-2222-2222-222222222222', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'dueno@nevado.test', 'x', now(), now(), now()),
  ('33333333-3333-3333-3333-333333333333', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'turista@test.test', 'x', now(), now(), now()),
  ('44444444-4444-4444-4444-444444444444', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'otro@test.test',    'x', now(), now(), now());

insert into public.merchants (id, nombre, rubro, activo) values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Fogón de prueba',  'restaurante', true),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'Nevado de prueba', 'cerveceria',  true),
  ('cccccccc-cccc-cccc-cccc-cccccccccccc', 'Cerrado de prueba', 'minimarket', false);

insert into public.merchant_users (merchant_id, auth_user_id, email, rol) values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '11111111-1111-1111-1111-111111111111', 'dueno@fogon.test',  'dueno'),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', '22222222-2222-2222-2222-222222222222', 'dueno@nevado.test', 'dueno');

insert into public.users (id, telefono, nombre) values
  ('33333333-3333-3333-3333-333333333333', '+56911111111', 'Turista'),
  ('44444444-4444-4444-4444-444444444444', '+56922222222', 'Otro turista');

-- El trigger le puso su secreto a cada comercio, sin que nadie lo pidiera.
do $$
declare n int;
begin
  select count(*) into n from public.merchant_secrets
  where merchant_id in ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
                        'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
                        'cccccccc-cccc-cccc-cccc-cccccccccccc');
  if n <> 3 then
    raise exception 'FALLA: se esperaban 3 secretos autocreados y hay %', n;
  end if;
  raise notice 'OK  · cada comercio nace con su hmac_secret';
end $$;

-- ---------------------------------------------------------------------------
-- Con el token de Fogón
-- ---------------------------------------------------------------------------

set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';

do $$
declare n int; quien text;
begin
  -- La prueba que pidió el plan: la cuenta de un local se ve solo a sí misma.
  select count(*) into n from public.merchants;
  if n <> 1 then
    raise exception 'FALLA: Fogón ve % comercios, debería ver solo el suyo', n;
  end if;
  select nombre into quien from public.merchants;
  if quien <> 'Fogón de prueba' then
    raise exception 'FALLA: Fogón ve el comercio "%"', quien;
  end if;
  raise notice 'OK  · Fogón solo se ve a sí mismo en merchants';

  select count(*) into n from public.merchant_users;
  if n <> 1 then
    raise exception 'FALLA: Fogón ve % logins, debería ver solo el suyo', n;
  end if;
  raise notice 'OK  · Fogón no ve los logins de Nevado';

  -- El secreto de firma no se lee por la API ni siendo el dueño del local.
  begin
    perform 1 from public.merchant_secrets;
    raise exception 'FALLA: merchant_secrets es legible desde la API';
  exception when insufficient_privilege then
    raise notice 'OK  · merchant_secrets no es legible por la API';
  end;

  -- Tocar el comercio de al lado no da error: simplemente no alcanza ninguna fila.
  update public.merchants set nombre = 'Secuestrado' where id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
  get diagnostics n = row_count;
  if n <> 0 then
    raise exception 'FALLA: Fogón modificó % filas de otro comercio', n;
  end if;
  raise notice 'OK  · Fogón no puede modificar a Nevado';

  -- Los datos de un usuario final no son suyos.
  select count(*) into n from public.users;
  if n <> 0 then
    raise exception 'FALLA: Fogón lee % filas de users sin haber validado ningún canje', n;
  end if;
  raise notice 'OK  · Fogón no lee usuarios (en T3 se abrirá solo a quienes canjeen con él)';
end $$;

-- ---------------------------------------------------------------------------
-- Con el token de un usuario final
-- ---------------------------------------------------------------------------

set local request.jwt.claims = '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}';

do $$
declare n int;
begin
  -- Ve la red activa, no la cerrada.
  -- Filtrado a los tres comercios de esta prueba: desde la 002 la base trae además los 8 de la
  -- semilla, y contar la tabla entera mediría el seed en vez del aislamiento.
  select count(*) into n from public.merchants
  where id in ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
               'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
               'cccccccc-cccc-cccc-cccc-cccccccccccc');
  if n <> 2 then
    raise exception 'FALLA: el usuario ve % comercios de prueba; deberían ser los 2 activos', n;
  end if;
  raise notice 'OK  · el usuario ve la red activa y no el comercio apagado';

  select count(*) into n from public.users;
  if n <> 1 then
    raise exception 'FALLA: el usuario lee % filas de users, debería leer solo la suya', n;
  end if;
  raise notice 'OK  · el usuario solo se lee a sí mismo';

  select count(*) into n from public.merchant_users;
  if n <> 0 then
    raise exception 'FALLA: el usuario lee % logins de comercio', n;
  end if;
  raise notice 'OK  · el usuario no ve los logins de los locales';

  -- Los parámetros se leen, pero no se tocan.
  select count(*) into n from public.settings;
  if n <> 11 then
    raise exception 'FALLA: settings devuelve % filas, deberían ser los 11 parámetros semilla', n;
  end if;
  update public.settings set value = '999' where key = 'ttl_codigo_canje_minutos';
  get diagnostics n = row_count;
  if n <> 0 then
    raise exception 'FALLA: un usuario cambió % parámetros del negocio', n;
  end if;
  raise notice 'OK  · settings se lee pero solo el admin lo escribe';

  -- Y no puede inventarse un comercio.
  begin
    insert into public.merchants (nombre, rubro) values ('Local trucho', 'otro');
    raise exception 'FALLA: un usuario final creó un comercio';
  exception when insufficient_privilege then
    raise notice 'OK  · un usuario final no puede crear comercios';
  end;

  -- Ni suplantar a otro usuario.
  begin
    insert into public.users (id, telefono) values ('22222222-2222-2222-2222-222222222222', '+56900000000');
    raise exception 'FALLA: un usuario creó la fila de otro';
  exception when insufficient_privilege then
    raise notice 'OK  · un usuario no puede crear la fila de otro';
  end;
end $$;

reset role;

do $$ begin raise notice 'TODO OK · la migración 001 aísla lo que debe aislar'; end $$;

rollback;
