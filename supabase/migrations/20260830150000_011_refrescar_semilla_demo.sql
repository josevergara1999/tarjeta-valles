-- Migración 011 — Re-anclar la semilla de demostración a hoy
-- Hito 1 · reparación de la semilla de T3. Referencia: docs/seed-data.md, escenario 4.
--
-- LA SEMILLA SE PUDRE SOLA. La 005 escribió sus fechas como `now() - interval '2 days'`, evaluado en
-- el instante en que se aplicó la migración. Ese instante se aleja un día por cada día que pasa, así
-- que los canjes "recientes" del turista dejan de ser recientes y los escenarios de `seed-data.md`
-- desaparecen sin que nadie toque nada:
--
--   · El escenario 4 ("Vuelve en 2 días") necesita DOS comercios en cooldown. A los tres días de
--     aplicada la 005 queda uno, y a los cuatro, ninguno.
--   · El pase del turista vencía `now() + 3 days`. Pasada esa semana, el usuario semilla que existe
--     para probar canjes no tiene con qué canjear.
--
-- Esto se detectó el 30-ago-2026 al correr por primera vez `supabase/tests/005_rls.sql`, dos días
-- después de sembrar: la prueba del cooldown falló contando 1 comercio donde `seed-data.md` promete
-- 2. La prueba tenía razón; los datos habían envejecido.
--
-- La reparación no es aflojar la prueba. Es poder devolver la semilla a su forma original cuando haga
-- falta, y que la prueba lo haga por su cuenta dentro de su transacción para no depender del
-- calendario.

-- ---------------------------------------------------------------------------
-- `app.refrescar_semilla_demo()`
--
-- Desplaza TODAS las fechas de la semilla por un mismo intervalo. Un desplazamiento uniforme conserva
-- la estructura relativa completa —qué canje fue antes que cuál, cuánto duró cada ciclo, qué pase se
-- solapa con qué otro— y respeta por construcción las restricciones de orden de la 005
-- (`expira_at > created_at`, `fecha_expiracion > fecha_activacion`), porque sumar la misma constante
-- a los dos lados de una desigualdad no la altera.
--
-- El ancla se reconstruye de los propios datos: la 005 creó el canje '100001' exactamente un día
-- antes de aplicarse, así que ese instante es `created_at('100001') + 1 día`. No hace falta guardar
-- en ninguna parte cuándo se sembró.
--
-- Es idempotente: correrla dos veces seguidas da un delta de casi cero la segunda vez.
--
-- Vive en el esquema `app` y no en `public` a propósito: PostgREST solo publica `public`, así que
-- esto no existe como endpoint. Además se le revoca el permiso a todo el mundo salvo al dueño y a
-- `service_role`. Es una herramienta de desarrollo sobre datos de demostración, no una función del
-- producto: el día que entren comercios y usuarios reales, esta función deja de tener a quién tocar
-- —solo alcanza a los ids `5eed…`— y se puede borrar sin consecuencias.
-- ---------------------------------------------------------------------------

create function app.refrescar_semilla_demo()
returns interval
language plpgsql
volatile
set search_path = public, app, pg_temp
as $$
declare
  v_ancla timestamptz;
  v_delta interval;
begin
  select created_at + interval '1 day' into v_ancla
  from public.redemptions
  where codigo = '100001'
    and user_id = '5eed0002-0000-4000-a000-000000000002';

  if v_ancla is null then
    raise exception 'No hay semilla que refrescar: falta el canje 100001 de la 005.';
  end if;

  v_delta := now() - v_ancla;

  update public.entitlements
     set fecha_activacion = fecha_activacion + v_delta,
         fecha_expiracion = fecha_expiracion + v_delta
   where id::text like '5eed0003-%';

  update public.redemptions
     set created_at  = created_at  + v_delta,
         expira_at   = expira_at   + v_delta,
         validado_at = validado_at + v_delta
   where user_id::text like '5eed0002-%';

  -- `franja` y `dia_operativo` son columnas guardadas, no calculadas al vuelo: la 008 las llenó a
  -- partir de `created_at` para que mover una franja no reescriba el pasado. Al correr las fechas hay
  -- que recalcularlas, o un canje de la noche del martes seguiría diciendo que fue el martes.
  update public.redemptions
     set franja        = app.franja_en(created_at),
         dia_operativo = app.dia_operativo(created_at)
   where user_id::text like '5eed0002-%';

  return v_delta;
end $$;

comment on function app.refrescar_semilla_demo() is
  'Devuelve la semilla de demostración a la forma que describe seed-data.md, desplazando sus fechas hasta hoy. Solo toca los ids 5eed…. Devuelve cuánto había envejecido.';

revoke all on function app.refrescar_semilla_demo() from public;
grant execute on function app.refrescar_semilla_demo() to service_role;

-- ---------------------------------------------------------------------------
-- Y se corre una vez, porque la semilla de esta base ya está envejecida.
-- ---------------------------------------------------------------------------

do $$
declare
  v_delta    interval;
  v_cooldown int;
begin
  select app.refrescar_semilla_demo() into v_delta;

  -- La comprobación que falló en las pruebas: el turista tiene que quedar con dos comercios dentro de
  -- la ventana de cooldown. Si esto no se cumple después de refrescar, el desplazamiento no reprodujo
  -- el escenario y es mejor que la migración se caiga a que deje datos que mienten.
  select count(distinct merchant_id) into v_cooldown
  from public.redemptions
  where user_id = '5eed0002-0000-4000-a000-000000000002'
    and estado = 'validado'
    and validado_at > now() - (app.setting_int('cooldown_dias_default') || ' days')::interval;

  if v_cooldown <> 2 then
    raise exception 'La semilla refrescada deja % comercios en cooldown y el escenario 4 pide 2.', v_cooldown;
  end if;

  raise notice 'OK · semilla refrescada, había envejecido %.', v_delta;
end $$;
