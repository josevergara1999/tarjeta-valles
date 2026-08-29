-- Pruebas de la migración 004 — updated_at automático
--
-- Cómo se corre: pegar entero en el SQL Editor de Supabase (o `psql -f`). Termina en ROLLBACK.
--
-- Ojo con lo que se puede probar dentro de una transacción: `now()` devuelve la hora de INICIO de
-- la transacción, así que insertar y actualizar acá dentro da la misma marca y no probaría nada.
-- Lo que sí se comprueba, y es lo que importa, es que el trigger PISA el valor que mande el cliente:
-- nadie puede fingir cuándo se editó una regla.

begin;

insert into public.merchants (id, nombre, rubro, activo) values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Fogón de prueba', 'restaurante', true);

insert into public.benefits (id, merchant_id, tipo, titulo, condicion_consumo) values
  ('deadbee1-0000-4000-a000-000000000001', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
   'cortesia', 'Postre de prueba', 'con plato principal');

do $$
declare t timestamptz;
begin
  -- benefit_rules: el cliente miente, el trigger corrige.
  update public.benefit_rules
  set cupos_dia = 5, updated_at = '2000-01-01T00:00:00Z'
  where benefit_id = 'deadbee1-0000-4000-a000-000000000001';

  select updated_at into t from public.benefit_rules
  where benefit_id = 'deadbee1-0000-4000-a000-000000000001';

  if t < now() - interval '1 minute' then
    raise exception 'FALLA: benefit_rules.updated_at quedó en % — el trigger no pisó al cliente', t;
  end if;
  raise notice 'OK  · benefit_rules.updated_at lo pone la base, no quien escribe';

  -- settings: mismo trato.
  update public.settings
  set value = '5', updated_at = '2000-01-01T00:00:00Z'
  where key = 'ttl_codigo_canje_minutos';

  select updated_at into t from public.settings where key = 'ttl_codigo_canje_minutos';

  if t < now() - interval '1 minute' then
    raise exception 'FALLA: settings.updated_at quedó en % — el trigger no pisó al cliente', t;
  end if;
  raise notice 'OK  · settings.updated_at lo pone la base, no quien escribe';
end $$;

do $$ begin raise notice 'TODO OK · la migración 004 mantiene los updated_at'; end $$;

rollback;
