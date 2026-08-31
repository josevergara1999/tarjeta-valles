-- Migración 015 — El esquema `app` deja de ser alcanzable desde la API
-- Hito 1. Encontrado el 31-ago-2026 auditando privilegios tabla por tabla y función por función.
--
-- La 014 cerró `app.firmar_canje` y dijo, para justificar por qué eso no había sido explotable, que
-- "PostgREST publica únicamente el esquema public, así que un cliente de la app no tiene forma de
-- invocar nada de app". Eso es cierto de la API REST, pero la frase escondía una suposición falsa:
-- que el esquema estaba cerrado. **No lo estaba.** `authenticated` tenía USAGE sobre `app` y EXECUTE
-- sobre 25 de sus 26 funciones, heredado del permiso que toda función nueva concede a PUBLIC.
--
-- QUÉ HABÍA DETRÁS DE ESA PUERTA. Las funciones de `app` son casi todas SECURITY DEFINER —tienen que
-- serlo, porque leen tablas que RLS le esconde a quien llama— y tres reciben un `user_id` arbitrario:
--
--   app.giros_disponibles(p_user_id)                → el saldo de giros de CUALQUIER usuario
--   app.canjes_del_dia(p_user_id, p_dia)            → cuántas veces canjeó hoy CUALQUIER usuario
--   app.franja_gastada(p_user_id, p_franja, p_dia)  → si ya gastó su franja
--   app.usuario_canjeo_en(p_user_id, p_merchant_id) → si canjeó en tal local
--
-- Ninguna de ellas comprueba que el `user_id` que recibe sea el de quien llama, y no tienen por qué:
-- son piezas internas, invocadas siempre desde una función de `public` que ya resolvió quién es el
-- usuario. El problema nunca fue lo que hacen, sino quién podía llamarlas.
--
-- LA LECCIÓN, que ya va dos veces. "No es alcanzable" no es una propiedad del sistema, es una
-- observación sobre su configuración de hoy. Basta con marcar `app` en Exposed schemas del panel de
-- Supabase —un checkbox— para que las 26 funciones queden publicadas como endpoints REST. La defensa
-- tiene que estar en los permisos, que viajan con la base, y no en una casilla del panel.

-- ---------------------------------------------------------------------------
-- Cerrar el esquema entero
--
-- Se revoca a `public` además de a `anon` y `authenticated`: el permiso que hay que quitar es el del
-- pseudo-rol PUBLIC, que es de donde cuelgan todos. Nombrar solo a los roles concretos deja la
-- entrada `=X/` del ACL intacta y no cambia nada — es el error exacto que cometió la primera versión
-- de la 014.
-- ---------------------------------------------------------------------------

revoke usage on schema app from anon, authenticated;
revoke all on all functions in schema app from public, anon, authenticated;

-- Y que las funciones FUTURAS nazcan cerradas, para no tener que acordarse en cada migración. Sin
-- esto, la próxima función de `app` vuelve a nacer con EXECUTE para PUBLIC y este arreglo dura hasta
-- la siguiente tarea.
alter default privileges in schema app revoke execute on functions from public;

-- ---------------------------------------------------------------------------
-- Nada de esto rompe el producto
--
-- Las funciones de `public` que las usan —get_turn_state, get_available_benefits, create_redemption,
-- cancel_redemption— son todas SECURITY DEFINER. Dentro de ellas el usuario efectivo es el dueño, no
-- quien llamó, así que los permisos se comprueban contra `postgres` y siguen alcanzando.
--
-- Los triggers tampoco: Postgres exige EXECUTE sobre la función al CREAR el trigger, no cada vez que
-- se dispara.
--
-- Lo único que sí cambia son las pruebas de `supabase/tests/`, que llamaban a `app.franja_en` y
-- compañía como `authenticated` para calcular los valores esperados. Se les agregó un grant explícito
-- dentro de su propia transacción, que el rollback deshace.
-- ---------------------------------------------------------------------------

do $$
declare
  v_fns   text;
  v_esq   text;
begin
  select string_agg(p.proname || ' → ' || r.rolname, ', ' order by p.proname)
    into v_fns
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  cross join (values ('anon'), ('authenticated')) as r(rolname)
  where n.nspname = 'app'
    and has_function_privilege(r.rolname, p.oid, 'execute');

  if v_fns is not null then
    raise exception 'Quedaron funciones de app ejecutables desde la API: %', v_fns;
  end if;

  select string_agg(r.rolname, ', ')
    into v_esq
  from (values ('anon'), ('authenticated')) as r(rolname)
  where has_schema_privilege(r.rolname, 'app', 'usage');

  if v_esq is not null then
    raise exception 'Estos roles todavía pueden entrar al esquema app: %', v_esq;
  end if;

  -- Y lo que tiene que seguir en pie: los cuatro RPC del canje para el usuario logueado.
  if not has_function_privilege('authenticated', 'public.create_redemption(uuid)', 'execute')
     or not has_function_privilege('authenticated', 'public.cancel_redemption(uuid)', 'execute')
     or not has_function_privilege('authenticated', 'public.get_available_benefits()', 'execute')
     or not has_function_privilege('authenticated', 'public.get_turn_state()', 'execute') then
    raise exception 'Se cerró de más: `authenticated` perdió los RPC del canje.';
  end if;
end $$;
